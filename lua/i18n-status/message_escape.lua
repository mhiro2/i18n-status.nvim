---Encode plain text as a translation message that renders the same text.
local M = {}

-- ICU MessageFormat (next-intl) syntax characters at the top level of a message. `<` and `>`
-- start rich text tags.
local ICU_SYNTAX = { ["{"] = true, ["}"] = true, ["<"] = true, [">"] = true }

---Quote ICU syntax so next-intl renders the text literally.
---
---next-intl parses messages with apostrophe mode DOUBLE_OPTIONAL: an apostrophe opens a quoted
---literal only right before a syntax character, and `''` is a literal apostrophe both inside and
---outside quotes. Runs of syntax characters are quoted, and apostrophes are doubled wherever a
---single one could open or close a quote.
---@param text string
---@return string
local function escape_icu(text)
  local out = {}
  local quoted = false
  local len = #text
  for index = 1, len do
    local char = text:sub(index, index)
    if ICU_SYNTAX[char] then
      if not quoted then
        out[#out + 1] = "'"
        quoted = true
      end
      out[#out + 1] = char
    elseif char == "'" then
      local next_char = text:sub(index + 1, index + 1)
      local needs_double = quoted or ICU_SYNTAX[next_char] or next_char == "'" or text:sub(index - 1, index - 1) == "'"
      out[#out + 1] = needs_double and "''" or "'"
    else
      if quoted then
        out[#out + 1] = "'"
        quoted = false
      end
      out[#out + 1] = char
    end
  end
  if quoted then
    out[#out + 1] = "'"
  end
  return table.concat(out)
end

---@param framework 'i18next'|'next_intl'|string
---@param text string
---@return string|nil message
---@return string|nil error
function M.literal_message(framework, text)
  if framework == "next_intl" then
    return escape_icu(text), nil
  end
  -- i18next has no escape for interpolation or nesting markers, so such text cannot be stored
  -- without changing what is rendered.
  if text:find("{{", 1, true) or text:find("$t(", 1, true) then
    return nil, "text contains i18next interpolation or nesting syntax"
  end
  return text, nil
end

return M
