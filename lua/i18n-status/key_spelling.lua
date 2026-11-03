---Source spelling of canonical `namespace:path` keys.
---
---A key is written relative to the translator that owns the call: i18next translators bound to a
---namespace drop it (and may reach other namespaces with an explicit `ns:` prefix), while
---next-intl translators join their bound namespace with the source key into one message path.
local M = {}

local next_intl_key = require("i18n-status.next_intl_key")

---@class I18nStatusTranslationArg
---@field prefix string Text typed inside the string literal before the cursor
---@field quote string Quote character that opened the string literal
---@field quote_col integer 0-based byte column of the opening quote
---@field member_call boolean Whether the translator is called as a member (`i18n.t(...)`)

---Track strings, template interpolations, and comments up to the end of `before`.
---Quotes directly after a word (`Don't` in JSX text) and `//` after a URL scheme are text, not
---delimiters.
---@param before string
---@return string|nil quote Quote of the string literal open at the end, if any
---@return integer|nil quote_start 1-based index of that quote
---@return boolean|nil arg_member Member flag of the `t(` call whose first argument is that string
---@return boolean in_comment Whether the end of `before` is inside a comment
local function scan_line(before)
  local quote, quote_start = nil, nil
  ---@type boolean|nil Member flag of a `t(` that is still waiting for its first argument
  local pending = nil
  ---@type boolean|nil Member flag of the call whose first argument is the open string
  local arg_member = nil
  -- Brace depth of the code and, per open `${`, the depth at which its template resumes.
  local depth = 0
  local templates = {}
  local i, n = 1, #before
  while i <= n do
    local c = before:sub(i, i)
    local prev = i > 1 and before:sub(i - 1, i - 1) or ""
    if quote then
      if c == "\\" then
        i = i + 1
      elseif c == quote then
        quote, arg_member = nil, nil
      elseif quote == "`" and before:sub(i, i + 1) == "${" then
        quote, arg_member, pending = nil, nil, nil
        depth = depth + 1
        templates[#templates + 1] = depth
        i = i + 1
      end
    elseif before:sub(i, i + 1) == "//" and not before:sub(1, i - 1):match("%a:$") then
      return nil, nil, nil, true
    elseif before:sub(i, i + 1) == "/*" then
      local close = before:find("*/", i + 2, true)
      if not close then
        return nil, nil, nil, true
      end
      i = close + 1
    elseif c == "`" or ((c == '"' or c == "'") and not prev:match("[%w_$]")) then
      quote, quote_start = c, i
      arg_member, pending = pending, nil
    elseif c == "}" and templates[#templates] == depth then
      templates[#templates] = nil
      depth = depth - 1
      quote, arg_member, pending = "`", nil, nil
    else
      local call_end = c == "t" and not prev:match("[%w_$]") and select(2, before:find("^t%s*%(", i))
      if call_end then
        pending = prev == "."
        i = call_end
      elseif not c:match("%s") then
        pending = nil
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
        end
      end
    end
    i = i + 1
  end
  return quote, quote_start, arg_member, false
end

---Find the translation call whose first string argument contains the end of `before`, the line
---text up to the cursor. `t(` inside strings or comments, closed arguments such as `t("a") + "`,
---and calls like `axios.get("` do not count.
---@param before string
---@return I18nStatusTranslationArg|nil
function M.translation_arg_at(before)
  local quote, quote_start, arg_member = scan_line(before)
  if not quote or arg_member == nil then
    return nil
  end
  return {
    prefix = before:sub(quote_start + 1),
    quote = quote,
    quote_col = quote_start - 1,
    member_call = arg_member,
  }
end

---Quote of the string literal open at the end of `before`, the line text up to the cursor.
---@param before string
---@return string|nil
function M.open_quote_at(before)
  return (scan_line(before))
end

local OPAQUE_ERROR = "the translator's namespace or key options cannot be resolved statically"

---@param policy string|nil
---@param namespace string|nil
---@return I18nStatusKeySpelling|nil
---@return string|nil error
local function next_intl_spelling(policy, namespace)
  if policy == "namespace_relative" then
    return { framework = "next_intl", namespace = namespace }, nil
  end
  if policy == "canonical" then
    return { framework = "next_intl" }, nil
  end
  return nil, OPAQUE_ERROR
end

---@class I18nStatusKeySpelling
---@field framework 'next_intl'|nil Set when keys follow next-intl message paths
---@field namespace string|nil next-intl: namespace bound to the translator (nil for a root translator); otherwise the default namespace
---@field explicit_namespace boolean|nil Keep the `ns:` prefix even for keys in the default namespace

---Spelling rules of the translator described by a `scan.translation_context_at` result.
---@param context table
---@param fallback_ns string|nil Namespace assumed when no translator binding is found
---@return I18nStatusKeySpelling|nil
---@return string|nil error
function M.for_context(context, fallback_ns)
  if not context.found_hook then
    return { namespace = fallback_ns }, nil
  end
  if context.namespace_resolution == "dynamic" or (context.hook == "useTranslation" and not context.extract_safe) then
    return nil, OPAQUE_ERROR
  end
  if context.framework == "next_intl" then
    return next_intl_spelling(context.source_key_policy, context.namespace)
  end
  return { namespace = context.namespace }, nil
end

---Spelling rules of the translator that owns a `scan.extract` item.
---@param item table
---@param fallback_ns string|nil Namespace assumed when the call has no namespace binding
---@return I18nStatusKeySpelling|nil
---@return string|nil error
function M.for_item(item, fallback_ns)
  if item.opaque_binding then
    return nil, OPAQUE_ERROR
  end
  if item.framework == "next_intl" then
    return next_intl_spelling(item.source_key_policy, item.translator_namespace)
  end
  if item.fallback then
    return { namespace = fallback_ns }, nil
  end
  return { namespace = item.translator_namespace }, nil
end

---Source key that reaches canonical `key` under `spelling`.
---@param spelling I18nStatusKeySpelling
---@param key string Canonical `namespace:path` key
---@param opts? { qualify_other_namespaces?: boolean } Spell keys of other namespaces with an explicit `ns:` prefix instead of rejecting them
---@return string|nil
---@return string|nil error
function M.source_key(spelling, key, opts)
  if spelling.framework == "next_intl" then
    return next_intl_key.source_key(spelling.namespace, key)
  end
  local namespace = spelling.namespace
  if not namespace or namespace == "" then
    return key, nil
  end
  if key:sub(1, #namespace + 1) ~= namespace .. ":" then
    if opts and opts.qualify_other_namespaces then
      return key, nil
    end
    return nil, string.format("key '%s' is outside namespace '%s'", key, namespace)
  end
  if spelling.explicit_namespace then
    return key, nil
  end
  return key:sub(#namespace + 2), nil
end

---Spelling of a key outside any translator call: the full path of its own framework.
---@param key string Canonical `namespace:path` key
---@param framework string|nil Framework of the resource that defines the key
---@return string
function M.root_key(key, framework)
  if framework == "next_intl" then
    return (next_intl_key.source_key(nil, key)) or key
  end
  return key
end

return M
