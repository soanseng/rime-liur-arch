-- liu_gc_processor.lua
-- 上屏後執行小步垃圾回收，減少記憶體壓力
-- 適用於手機端（倉輸入法）和電腦端（鼠鬚管/小狼毫）

local function processor(key, env)
    local context = env.engine.context
    
    -- 初始化狀態記錄
    if env.prev_input == nil then
        env.prev_input = ""
        env.prev_composing = false
    end
    
    local current_input = context.input or ""
    local current_composing = context:is_composing()
    
    -- 檢測上屏事件：
    -- 1. 之前有輸入內容且在編輯狀態
    -- 2. 現在輸入為空且不在編輯狀態
    -- 這表示剛剛完成了一次上屏（文字被提交）
    if env.prev_input ~= "" and env.prev_composing and 
       current_input == "" and not current_composing then
        collectgarbage("step")
    end
    
    -- 記錄當前狀態供下次比較
    env.prev_input = current_input
    env.prev_composing = current_composing
    
    return 2  -- kNoop，不攔截按鍵
end

return processor