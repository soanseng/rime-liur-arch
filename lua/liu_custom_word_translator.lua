-- liu_custom_word_translator.lua
-- 自定詞翻譯器：讀取 openxiami_CustomWord.dict.yaml 並產生候選
-- type="custom" 讓 filter 可以識別

local custom_words = nil

local function load_custom_words()
    if custom_words then return custom_words end
    custom_words = {}

    local user_dir = rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir() or ""
    local shared_dir = rime_api and rime_api.get_shared_data_dir and rime_api.get_shared_data_dir() or ""

    local paths = {}
    if user_dir ~= "" then paths[#paths + 1] = user_dir .. "/openxiami_CustomWord.dict.yaml" end
    if shared_dir ~= "" then paths[#paths + 1] = shared_dir .. "/openxiami_CustomWord.dict.yaml" end

    for _, path in ipairs(paths) do
        local file = io.open(path, "r")
        if file then
            local in_data = false
            for line in file:lines() do
                if line == "..." then
                    in_data = true
                elseif in_data and #line > 0 and line:byte(1) ~= 35 then  -- 35 = '#'
                    local word, code = line:match("^([^\t]+)\t([^\t]+)$")
                    if word and code then
                        code = code:lower()
                        local list = custom_words[code]
                        if not list then
                            list = {}
                            custom_words[code] = list
                        end
                        list[#list + 1] = word
                    end
                end
            end
            file:close()
            break
        end
    end

    return custom_words
end

local function translator(input, seg, env)
    if seg:has_tag("abc") or seg:has_tag("mkst") then
        local words = load_custom_words()
        local list = words[input:lower()]
        if list then
            local start, _end = seg.start, seg._end
            for i = 1, #list do
                local cand = Candidate("custom", start, _end, list[i], "")
                cand.quality = 999
                yield(cand)
            end
        end
    end
end

return translator
