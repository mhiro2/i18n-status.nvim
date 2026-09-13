mod doctor;
mod hardcoded;
mod resolve;
mod resource;
mod rpc;
mod scan;
mod util;

use anyhow::{Context, Result};
use i18n_status_core::contract::{self, InitializeParams, InitializeResult};
use resource::index::IndexCache;
use rpc::{
    INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, Notification,
    REQUEST_CANCELLED, Response, RpcSender, Transport,
};
use serde_json::{Value, json};
use std::process;
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

const DOCTOR_CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(10);
const DOCTOR_CANCEL_GRACE: Duration = Duration::from_millis(50);
const MAX_DOCTOR_DEADLINE: Duration = Duration::from_secs(120);
// Rust cannot forcibly stop a thread. Capping outstanding tasks prevents repeated
// non-cooperative Doctor requests from leaking threads without bound.
const MAX_OUTSTANDING_DOCTOR_TASKS: usize = 2;

fn dispatch_doctor(
    params: doctor::DiagnoseParams,
    id: Option<Value>,
    sender: RpcSender,
    cancelled: &AtomicBool,
) -> Response {
    let request_id = id.clone().unwrap_or(Value::Null);
    let notify = |method: &str, mut params: Value| {
        if cancelled.load(Ordering::Acquire) {
            return;
        }
        if let Value::Object(payload) = &mut params {
            payload.insert("request_id".to_string(), request_id.clone());
        }
        let notification = Notification::new(method, params);
        let _ = sender.send_notification(&notification);
    };
    match doctor::diagnose(params, &notify, &|| cancelled.load(Ordering::Acquire)) {
        Ok(result) => Response::success(id, result),
        Err(error) => Response::error(id, INTERNAL_ERROR, error.to_string()),
    }
}

struct DoctorJob {
    params: doctor::DiagnoseParams,
    id: Option<Value>,
}

impl DoctorJob {
    fn deadline(&self) -> Duration {
        Duration::from_millis(self.params.deadline_ms.max(1)).min(MAX_DOCTOR_DEADLINE)
    }
}

#[derive(Default)]
struct DoctorQueue {
    active_cancel: Option<Arc<AtomicBool>>,
    pending: Option<DoctorJob>,
}

struct DoctorScheduler {
    queue: Arc<(Mutex<DoctorQueue>, Condvar)>,
    sender: RpcSender,
    worker_started: bool,
}

impl DoctorScheduler {
    fn new(sender: RpcSender) -> Self {
        Self {
            queue: Arc::new((Mutex::new(DoctorQueue::default()), Condvar::new())),
            sender,
            worker_started: false,
        }
    }

    fn ensure_worker(&mut self) -> Result<()> {
        self.ensure_worker_with(|queue, sender| {
            std::thread::Builder::new()
                .name("i18n-status-doctor".to_string())
                .stack_size(util::SERVER_STACK_SIZE)
                .spawn(move || run_doctor_worker(queue, sender))
                .map(|_| ())
        })
    }

    fn ensure_worker_with(
        &mut self,
        spawn: impl FnOnce(Arc<(Mutex<DoctorQueue>, Condvar)>, RpcSender) -> std::io::Result<()>,
    ) -> Result<()> {
        if self.worker_started {
            return Ok(());
        }
        spawn(Arc::clone(&self.queue), self.sender).context("failed to start doctor worker")?;
        self.worker_started = true;
        Ok(())
    }

    fn submit(&mut self, job: DoctorJob) {
        if let Err(error) = self.ensure_worker() {
            let response = Response::error(job.id, INTERNAL_ERROR, error.to_string());
            if let Err(error) = self.sender.send_response(&response) {
                eprintln!("i18n-status-core: send error: {error}");
            }
            return;
        }
        let superseded = {
            let (lock, ready) = &*self.queue;
            let mut queue = lock.lock().expect("doctor queue lock poisoned");
            if let Some(cancel) = &queue.active_cancel {
                cancel.store(true, Ordering::Release);
            }
            let superseded = queue.pending.replace(job);
            ready.notify_one();
            superseded
        };

        if let Some(job) = superseded {
            let response = Response::error(
                job.id,
                REQUEST_CANCELLED,
                "doctor request superseded by a newer request".to_string(),
            );
            if let Err(error) = self.sender.send_response(&response) {
                eprintln!("i18n-status-core: send error: {error}");
            }
        }
    }
}

fn run_doctor_worker(queue: Arc<(Mutex<DoctorQueue>, Condvar)>, sender: RpcSender) {
    let outstanding_tasks = Arc::new(AtomicUsize::new(0));
    loop {
        let (job, cancelled) = {
            let (lock, ready) = &*queue;
            let mut state = lock.lock().expect("doctor queue lock poisoned");
            while state.pending.is_none() {
                state = ready.wait(state).expect("doctor queue lock poisoned");
            }
            let job = state
                .pending
                .take()
                .expect("pending doctor job disappeared");
            let cancelled = Arc::new(AtomicBool::new(false));
            state.active_cancel = Some(Arc::clone(&cancelled));
            (job, cancelled)
        };

        let response = run_doctor_job(
            job,
            sender,
            Arc::clone(&cancelled),
            Arc::clone(&outstanding_tasks),
        );
        if let Err(error) = sender.send_response(&response) {
            eprintln!("i18n-status-core: send error: {error}");
        }

        let (lock, _) = &*queue;
        let mut state = lock.lock().expect("doctor queue lock poisoned");
        if state
            .active_cancel
            .as_ref()
            .is_some_and(|active| Arc::ptr_eq(active, &cancelled))
        {
            state.active_cancel = None;
        }
    }
}

fn run_doctor_job(
    job: DoctorJob,
    sender: RpcSender,
    cancelled: Arc<AtomicBool>,
    outstanding_tasks: Arc<AtomicUsize>,
) -> Response {
    run_doctor_job_with(
        job,
        cancelled,
        outstanding_tasks,
        move |job, task_cancelled| {
            let id = job.id.clone();
            dispatch_doctor(job.params, id, sender, &task_cancelled)
        },
    )
}

fn run_doctor_job_with(
    job: DoctorJob,
    cancelled: Arc<AtomicBool>,
    outstanding_tasks: Arc<AtomicUsize>,
    execute: impl FnOnce(DoctorJob, Arc<AtomicBool>) -> Response + Send + 'static,
) -> Response {
    let deadline = job.deadline();
    let response_id = job.id.clone();
    if outstanding_tasks
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_OUTSTANDING_DOCTOR_TASKS).then_some(count + 1)
        })
        .is_err()
    {
        return Response::error(
            response_id,
            INTERNAL_ERROR,
            "doctor is temporarily busy because task capacity is exhausted; retry after prior tasks finish"
                .to_string(),
        );
    }
    let task_response_id = response_id.clone();
    let (response_tx, response_rx) = mpsc::sync_channel(1);
    let task_cancelled = Arc::clone(&cancelled);
    let task_count = Arc::clone(&outstanding_tasks);
    let spawned = std::thread::Builder::new()
        .name("i18n-status-doctor-task".to_string())
        .stack_size(util::SERVER_STACK_SIZE)
        .spawn(move || {
            let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                execute(job, task_cancelled)
            }))
            .unwrap_or_else(|_| {
                Response::error(
                    task_response_id,
                    INTERNAL_ERROR,
                    "internal error: request handler panicked".to_string(),
                )
            });
            task_count.fetch_sub(1, Ordering::AcqRel);
            let _ = response_tx.send(response);
        });

    if let Err(error) = spawned {
        outstanding_tasks.fetch_sub(1, Ordering::AcqRel);
        return Response::error(
            response_id,
            INTERNAL_ERROR,
            format!("failed to start doctor task: {error}"),
        );
    }

    let started = Instant::now();
    loop {
        if cancelled.load(Ordering::Acquire) {
            let _ = response_rx.recv_timeout(DOCTOR_CANCEL_GRACE);
            return Response::error(
                response_id,
                REQUEST_CANCELLED,
                "doctor request cancelled".to_string(),
            );
        }

        let remaining = deadline.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            cancelled.store(true, Ordering::Release);
            let _ = response_rx.recv_timeout(DOCTOR_CANCEL_GRACE);
            return Response::error(
                response_id,
                REQUEST_CANCELLED,
                format!(
                    "doctor request exceeded {}ms deadline",
                    deadline.as_millis()
                ),
            );
        }

        match response_rx.recv_timeout(remaining.min(DOCTOR_CANCEL_POLL_INTERVAL)) {
            Ok(response) => return response,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Response::error(
                    response_id,
                    INTERNAL_ERROR,
                    "doctor task ended without a response".to_string(),
                );
            }
        }
    }
}

struct Server {
    transport: Transport,
    doctor_scheduler: DoctorScheduler,
    index_cache: IndexCache,
    initialized: bool,
}

impl Server {
    fn new() -> Self {
        let transport = Transport::new();
        let doctor_scheduler = DoctorScheduler::new(transport.sender());
        Self {
            transport,
            doctor_scheduler,
            index_cache: IndexCache::new(),
            initialized: false,
        }
    }

    fn run(&mut self) -> Result<()> {
        eprintln!("i18n-status-core: server starting");

        loop {
            let request = match self.transport.read_message() {
                Ok(Some(req)) => req,
                Ok(None) => {
                    eprintln!("i18n-status-core: EOF, shutting down");
                    break;
                }
                Err(e) => {
                    if e.to_string().contains("failed to read from stdin") {
                        break;
                    }
                    eprintln!("i18n-status-core: read error: {}", e);
                    continue;
                }
            };

            if request.jsonrpc != "2.0" {
                if request.id.is_some() {
                    let response = Response::error(
                        request.id.clone(),
                        INVALID_REQUEST,
                        "invalid jsonrpc version".to_string(),
                    );
                    let _ = self.transport.send_response(&response);
                }
                continue;
            }

            // Notifications have no id
            if request.id.is_none() {
                continue;
            }

            let id = request.id.clone();
            if !self.initialized && request.method != "initialize" && request.method != "shutdown" {
                let response = Response::error(
                    id,
                    INVALID_REQUEST,
                    "core is not initialized; complete the version handshake first".to_string(),
                );
                if let Err(error) = self.transport.send_response(&response) {
                    eprintln!("i18n-status-core: send error: {error}");
                }
                continue;
            }

            if request.method == "doctor/diagnose" {
                match serde_json::from_value(request.params) {
                    Ok(params) => self.doctor_scheduler.submit(DoctorJob { params, id }),
                    Err(error) => {
                        let response = Response::error(id, INVALID_PARAMS, error.to_string());
                        if let Err(error) = self.transport.send_response(&response) {
                            eprintln!("i18n-status-core: send error: {error}");
                        }
                    }
                }
                continue;
            }

            // A panic inside a handler must not take down the long-running
            // server. Catch it and downgrade it to a JSON-RPC error so the
            // editor's i18n features keep working without a restart.
            let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                self.dispatch(&request.method, request.params, id.clone())
            }))
            .unwrap_or_else(|_| {
                Response::error(
                    id.clone(),
                    INTERNAL_ERROR,
                    "internal error: request handler panicked".to_string(),
                )
            });
            if let Err(e) = self.transport.send_response(&response) {
                eprintln!("i18n-status-core: send error: {}", e);
            }
        }

        Ok(())
    }

    fn dispatch(&mut self, method: &str, params: Value, id: Option<Value>) -> Response {
        if !self.initialized && method != "initialize" && method != "shutdown" {
            return Response::error(
                id,
                INVALID_REQUEST,
                "core is not initialized; complete the version handshake first".to_string(),
            );
        }

        match method {
            "initialize" => match serde_json::from_value::<InitializeParams>(params) {
                Ok(params) => match contract::validate_client(&params) {
                    Ok(()) => {
                        self.initialized = true;
                        Response::success(id, json!(InitializeResult::current()))
                    }
                    Err(error) => Response::error(id, INVALID_REQUEST, error),
                },
                Err(error) => Response::error(id, INVALID_PARAMS, error.to_string()),
            },

            "shutdown" => {
                eprintln!("i18n-status-core: shutdown requested");
                let resp = Response::success(id, json!(null));
                // Send response then exit
                let _ = self.transport.send_response(&resp);
                process::exit(0);
            }

            "scan/extract" => match serde_json::from_value(params) {
                Ok(p) => match scan::extract(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "scan/extractResource" => match serde_json::from_value(params) {
                Ok(p) => match scan::extract_resource(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "scan/translationContextAt" => match serde_json::from_value(params) {
                Ok(p) => match scan::translation_context_at(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resolve/compute" => match serde_json::from_value(params) {
                Ok(p) => match resolve::compute(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/buildIndex" => match serde_json::from_value(params) {
                Ok(p) => match resource::index::build_index(p, &self.index_cache) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/resolveRoots" => match serde_json::from_value(params) {
                Ok(p) => match resource::discovery::resolve_roots(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/applyChanges" => match serde_json::from_value(params) {
                Ok(p) => match resource::index::apply_changes(p, &self.index_cache) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "hardcoded/extract" => match serde_json::from_value(params) {
                Ok(p) => match hardcoded::extract(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            _ => Response::error(
                id,
                METHOD_NOT_FOUND,
                format!("method not found: {}", method),
            ),
        }
    }
}

fn run_server() -> Result<()> {
    let mut server = Server::new();
    server.run()
}

fn main() {
    // Log handler panics with our prefix; the run loop catches them and keeps
    // the server alive (see catch_unwind above).
    std::panic::set_hook(Box::new(|info| {
        eprintln!("i18n-status-core: handler panic: {}", info);
    }));

    // Run the server on a thread with a large stack. swc recurses on syntactic
    // nesting and drops its AST recursively, so deeply nested source can overflow
    // the default stack and abort the process before catch_unwind can intervene.
    let worker = std::thread::Builder::new()
        .stack_size(util::SERVER_STACK_SIZE)
        .spawn(run_server)
        .expect("failed to spawn server thread");

    match worker.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            eprintln!("i18n-status-core: fatal error: {}", e);
            process::exit(1);
        }
        Err(_) => {
            eprintln!("i18n-status-core: server thread panicked");
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use i18n_status_core::contract::{CLIENT_NAME, CORE_NAME, CORE_VERSION, PROTOCOL_VERSION};

    fn initialize_params(version: &str, protocol_version: u32) -> Value {
        json!({
            "client": {
                "name": CLIENT_NAME,
                "version": version,
            },
            "protocol_version": protocol_version,
        })
    }

    fn doctor_job(id: u64, deadline_ms: u64) -> DoctorJob {
        DoctorJob {
            params: doctor::DiagnoseParams {
                project_root: ".".to_string(),
                roots: vec![],
                primary_lang: "en".to_string(),
                languages: vec!["en".to_string()],
                fallback_namespace: "translation".to_string(),
                ignore_patterns: vec![],
                open_buf_paths: vec![],
                open_buffers: vec![],
                cancel_token_path: None,
                deadline_ms,
            },
            id: Some(json!(id)),
        }
    }

    #[test]
    fn doctor_worker_start_failure_does_not_poison_the_scheduler() {
        let mut scheduler = DoctorScheduler::new(RpcSender);
        let error = scheduler
            .ensure_worker_with(|_, _| {
                Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "thread limit reached",
                ))
            })
            .expect_err("injected spawn failure should be returned");

        assert!(error.to_string().contains("failed to start doctor worker"));
        assert!(!scheduler.worker_started);
        assert!(scheduler.ensure_worker().is_ok());
    }

    #[test]
    fn doctor_deadline_cancels_hung_task_and_allows_the_next_job() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let outstanding_tasks = Arc::new(AtomicUsize::new(0));
        let task_finished = Arc::new(AtomicBool::new(false));
        let task_finished_in_worker = Arc::clone(&task_finished);
        let started = Instant::now();
        let response = run_doctor_job_with(
            doctor_job(1, 20),
            Arc::clone(&cancelled),
            Arc::clone(&outstanding_tasks),
            move |job, task_cancelled| {
                while !task_cancelled.load(Ordering::Acquire) {
                    std::thread::sleep(Duration::from_millis(1));
                }
                task_finished_in_worker.store(true, Ordering::Release);
                Response::success(job.id, json!({ "late": true }))
            },
        );

        assert_eq!(
            response.error.as_ref().map(|error| error.code),
            Some(REQUEST_CANCELLED)
        );
        assert!(
            response
                .error
                .as_ref()
                .is_some_and(|error| error.message.contains("deadline"))
        );
        assert!(cancelled.load(Ordering::Acquire));
        assert!(task_finished.load(Ordering::Acquire));
        assert_eq!(outstanding_tasks.load(Ordering::Acquire), 0);

        let next = run_doctor_job_with(
            doctor_job(2, 1_000),
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&outstanding_tasks),
            |job, _| Response::success(job.id, json!({ "ready": true })),
        );
        assert_eq!(
            next.result
                .as_ref()
                .and_then(|value| value["ready"].as_bool()),
            Some(true)
        );
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "scheduler path stayed blocked by the timed-out task"
        );
    }

    #[test]
    fn doctor_task_capacity_bounds_non_cooperative_timeouts() {
        let outstanding_tasks = Arc::new(AtomicUsize::new(0));
        let release_tasks = Arc::new(AtomicBool::new(false));

        let run_stalled = |id| {
            let release_task = Arc::clone(&release_tasks);
            run_doctor_job_with(
                doctor_job(id, 5),
                Arc::new(AtomicBool::new(false)),
                Arc::clone(&outstanding_tasks),
                move |job, _| {
                    while !release_task.load(Ordering::Acquire) {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Response::success(job.id, json!({ "released": true }))
                },
            )
        };

        let first = run_stalled(1);
        assert_eq!(
            first.error.as_ref().map(|error| error.code),
            Some(REQUEST_CANCELLED)
        );

        let replacement = run_doctor_job_with(
            doctor_job(2, 1_000),
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&outstanding_tasks),
            |job, _| Response::success(job.id, json!({ "ready": true })),
        );
        assert_eq!(
            replacement
                .result
                .as_ref()
                .and_then(|value| value["ready"].as_bool()),
            Some(true)
        );

        let second = run_stalled(3);
        assert_eq!(
            second.error.as_ref().map(|error| error.code),
            Some(REQUEST_CANCELLED)
        );

        let rejected = run_doctor_job_with(
            doctor_job(4, 1_000),
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&outstanding_tasks),
            |job, _| Response::success(job.id, json!({ "unexpected": true })),
        );
        release_tasks.store(true, Ordering::Release);

        assert!(
            rejected
                .error
                .as_ref()
                .is_some_and(|error| error.message.contains("capacity"))
        );
        assert_eq!(
            rejected.error.as_ref().map(|error| error.code),
            Some(INTERNAL_ERROR)
        );
        assert!(
            rejected
                .error
                .as_ref()
                .is_some_and(|error| !error.message.contains("cancel"))
        );
        let wait_started = Instant::now();
        while outstanding_tasks.load(Ordering::Acquire) != 0
            && wait_started.elapsed() < Duration::from_millis(500)
        {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(outstanding_tasks.load(Ordering::Acquire), 0);
    }

    #[test]
    fn rejects_normal_requests_before_initialization() {
        let mut server = Server::new();
        let response = server.dispatch("scan/extract", json!({}), Some(json!(1)));

        assert_eq!(
            response.error.expect("expected error").code,
            INVALID_REQUEST
        );
        assert!(!server.initialized);
    }

    #[test]
    fn rejects_an_incompatible_client_without_initializing() {
        let mut server = Server::new();
        let response = server.dispatch(
            "initialize",
            initialize_params("9.9.9", PROTOCOL_VERSION),
            Some(json!(1)),
        );

        assert_eq!(
            response.error.expect("expected error").code,
            INVALID_REQUEST
        );
        assert!(!server.initialized);
    }

    #[test]
    fn initializes_only_with_the_exact_contract() {
        let mut server = Server::new();
        let response = server.dispatch(
            "initialize",
            initialize_params(CORE_VERSION, PROTOCOL_VERSION),
            Some(json!(1)),
        );
        let result = response.result.expect("expected initialize result");

        assert_eq!(result["core"]["name"], CORE_NAME);
        assert_eq!(result["core"]["version"], CORE_VERSION);
        assert_eq!(result["protocol_version"], PROTOCOL_VERSION);
        assert!(server.initialized);
    }

    #[test]
    fn rejects_a_different_protocol_version() {
        let mut server = Server::new();
        let response = server.dispatch(
            "initialize",
            initialize_params(CORE_VERSION, PROTOCOL_VERSION + 1),
            Some(json!(1)),
        );

        assert_eq!(
            response.error.expect("expected error").code,
            INVALID_REQUEST
        );
        assert!(!server.initialized);
    }
}
