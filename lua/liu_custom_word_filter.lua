-- liu_custom_word_filter.lua
-- 排序過濾器：一般漢字(完整) > 自定詞(完整) > 一般漢字(補字) > 自定詞(補全) > 假名 > 擴充 > 英文
-- 使用串流處理優化效能，限制暫存數量避免大字典效能問題
-- custom = 完整匹配自定詞，custom_completion = 自定詞補全候選

local common = require("liu_common")
local is_kana = common.is_kana
local is_extended_charset = common.is_extended_charset

-- 最大暫存數量，超過後直接輸出
local MAX_BUFFER = 100

local function is_ascii_english(text)
    local len = #text
    if len == 0 or string.byte(text, 1) > 127 then return false end
    local has_letter = false
    for i = 1, len do
        local b = string.byte(text, i)
        if b > 126 or b < 32 then return false end
        if not has_letter and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122)) then
            has_letter = true
        end
    end
    return has_letter
end

local function get_cjk_type(text)
    for _, code in utf8.codes(text) do
        if is_extended_charset(code) then return 2 end
        if is_kana(code) then return 1 end
    end
    return 0
end

-- 輸出暫存的自定詞（完整匹配）
local function flush_custom(custom_cands)
    for i = 1, #custom_cands do yield(custom_cands[i]) end
end

-- 輸出暫存的補字候選和自定詞補全
local function flush_completion(completion_cands, custom_completion_cands)
    for i = 1, #completion_cands do yield(completion_cands[i]) end
    for i = 1, #custom_completion_cands do yield(custom_completion_cands[i]) end
end

local function filter(input, env)
    local custom_cands = {}           -- 完整匹配自定詞
    local custom_completion_cands = {} -- 自定詞補全候選
    local completion_cands = {}       -- 漢字補字候選（暫存）
    local kana_cands = {}
    local ext_cands = {}
    local english_cands = {}
    local custom_yielded = false
    local custom_completion_yielded = false
    local in_completion_phase = false  -- 是否進入補字階段
    local show_extended = env.engine.context:get_option("extended_charset")
    local overflow = false  -- 是否已超過暫存限制

    for cand in input:iter() do
        -- 如果已超過暫存限制，直接輸出所有候選
        if overflow then
            yield(cand)
        else
            local ctype = cand.type

            if ctype == "custom" then
                -- 完整匹配自定詞
                if custom_yielded then
                    yield(cand)
                else
                    custom_cands[#custom_cands + 1] = cand
                end
            elseif ctype == "custom_completion" then
                -- 自定詞補全候選
                if custom_completion_yielded then
                    yield(cand)
                else
                    if #custom_completion_cands < MAX_BUFFER then
                        custom_completion_cands[#custom_completion_cands + 1] = cand
                    else
                        yield(cand)
                    end
                end
            elseif is_ascii_english(cand.text) then
                -- 遇到英文，表示漢字階段結束
                -- 先輸出所有暫存的自定詞、補字候選和自定詞補全
                if not custom_yielded then
                    custom_yielded = true
                    flush_custom(custom_cands)
                    custom_cands = {}
                end
                if not custom_completion_yielded then
                    custom_completion_yielded = true
                    flush_completion(completion_cands, custom_completion_cands)
                    completion_cands = {}
                    custom_completion_cands = {}
                end
                
                if #english_cands < MAX_BUFFER then
                    english_cands[#english_cands + 1] = cand
                else
                    -- 超過限制，輸出所有暫存並切換到直接輸出模式
                    for i = 1, #kana_cands do yield(kana_cands[i]) end
                    for i = 1, #ext_cands do yield(ext_cands[i]) end
                    for i = 1, #english_cands do yield(english_cands[i]) end
                    yield(cand)
                    overflow = true
                    kana_cands, ext_cands, english_cands = {}, {}, {}
                end
            else
                local cjk_type = get_cjk_type(cand.text)

                if cjk_type == 2 then
                    -- 擴充字集，表示漢字補字階段結束
                    if not custom_yielded then
                        custom_yielded = true
                        flush_custom(custom_cands)
                        custom_cands = {}
                    end
                    if not custom_completion_yielded then
                        custom_completion_yielded = true
                        flush_completion(completion_cands, custom_completion_cands)
                        completion_cands = {}
                        custom_completion_cands = {}
                    end
                    
                    if show_extended then
                        if #ext_cands < MAX_BUFFER then
                            ext_cands[#ext_cands + 1] = cand
                        else
                            yield(cand)
                        end
                    end
                elseif cjk_type == 1 then
                    -- 假名，表示漢字補字階段結束
                    if not custom_yielded then
                        custom_yielded = true
                        flush_custom(custom_cands)
                        custom_cands = {}
                    end
                    if not custom_completion_yielded then
                        custom_completion_yielded = true
                        flush_completion(completion_cands, custom_completion_cands)
                        completion_cands = {}
                        custom_completion_cands = {}
                    end
                    
                    if #kana_cands < MAX_BUFFER then
                        kana_cands[#kana_cands + 1] = cand
                    else
                        yield(cand)
                    end
                else
                    local comment = cand.comment
                    -- 判斷是否為補字候選：
                    -- 1. comment 以 ~ 開頭（原始 completion 格式）
                    -- 2. comment 中有 ▸ 符號（轉換後的格式）
                    local is_completion = comment and (comment:sub(1, 1) == "~" or comment:find("▸", 1, true))

                    if not is_completion then
                        -- 完整匹配漢字，直接輸出
                        yield(cand)
                    else
                        -- 遇到補字候選，先輸出自定詞（完整匹配）
                        if not custom_yielded then
                            custom_yielded = true
                            flush_custom(custom_cands)
                            custom_cands = {}
                        end
                        
                        -- 進入補字階段，暫存補字候選
                        in_completion_phase = true
                        if #completion_cands < MAX_BUFFER then
                            completion_cands[#completion_cands + 1] = cand
                        else
                            -- 補字候選超過限制，直接輸出
                            yield(cand)
                        end
                    end
                end
            end
        end
    end

    -- 輸出剩餘候選
    if not overflow then
        flush_custom(custom_cands)
        flush_completion(completion_cands, custom_completion_cands)
        for i = 1, #kana_cands do yield(kana_cands[i]) end
        for i = 1, #ext_cands do yield(ext_cands[i]) end
        for i = 1, #english_cands do yield(english_cands[i]) end
    end
end

return filter
