-- liu_completion_translator.lua
-- 排序過濾器：自定詞排在完整匹配後面，英文排最後
-- 優化版本：減少記憶體使用

local common = require("liu_common")
local is_extended_charset = common.is_extended_charset

local function is_pure_ascii_english(text)
    if not text or #text == 0 then return false end
    local b = string.byte(text, 1)
    if b > 127 then return false end
    local has_letter = false
    for i = 1, #text do
        b = string.byte(text, i)
        if b > 126 or b < 32 then return false end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            has_letter = true
        end
    end
    return has_letter
end

local function filter(input, env)
    local custom_cands = {}
    local english_cands = {}
    local show_extended = env.engine.context:get_option("extended_charset")
    local had_exact_match = false

    for cand in input:iter() do
        local text = cand.text

        if cand.type == "custom" then
            if had_exact_match then
                yield(cand)
            else
                table.insert(custom_cands, cand)
            end
        elseif is_pure_ascii_english(text) then
            table.insert(english_cands, cand)
        else
            -- 檢查擴充字集
            local is_ext = false
            for _, code in utf8.codes(text) do
                if is_extended_charset(code) then
                    is_ext = true
                    break
                end
            end

            if is_ext and not show_extended then
                -- skip
            else
                local comment = cand.comment or ""
                local is_completion = comment:find("▸", 1, true) ~= nil
                
                if not is_completion and not had_exact_match then
                    had_exact_match = true
                    yield(cand)
                    -- 輸出自定詞
                    for _, c in ipairs(custom_cands) do yield(c) end
                    custom_cands = {}
                else
                    yield(cand)
                end
            end
        end
    end

    -- 剩餘的自定詞
    for _, c in ipairs(custom_cands) do yield(c) end
    -- 英文排最後
    for _, c in ipairs(english_cands) do yield(c) end
end

return filter
