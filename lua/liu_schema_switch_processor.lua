-- liu_schema_switch_processor.lua
-- 方案切換時保持 ascii_mode 狀態的處理器
-- 解決從 easy_en 切換回 liur 時 ascii_mode 被重置的問題

-- 全局狀態存儲
-- 使用 _G 確保跨方案共享狀態
_G.liu_schema_switch_state = _G.liu_schema_switch_state or {
  saved_ascii_mode = nil,      -- 保存的 ascii_mode 狀態 (true/false/nil)
  saved_from_schema = nil,     -- 來源方案 ID
  saved_timestamp = nil,       -- 保存時間戳
  pending_restore = false,     -- 是否有待恢復的狀態
  restore_attempted = false    -- 是否已嘗試恢復（防止重複恢復）
}

-- 配置常量
local CONFIG = {
  STATE_TIMEOUT = 300,         -- 狀態過期時間（秒）
  TARGET_SCHEMAS = {           -- 目標方案列表
    liur = true,
    easy_en = true
  }
}

-- 檢查是否為 Ctrl+/ 按鍵
local function is_ctrl_slash(key)
  if key:ctrl() and not key:alt() and not key:shift() then
    local keycode = key.keycode
    if keycode == 47 or keycode == 0x2f then
      return true
    end
  end
  return false
end

-- 檢查是否為目標方案
local function is_target_schema(schema_id)
  return CONFIG.TARGET_SCHEMAS[schema_id] == true
end

-- 獲取當前 ascii_mode 狀態
local function get_ascii_mode(env)
  local ok, result = pcall(function()
    local context = env.engine.context
    if context and context.get_option then
      return context:get_option("ascii_mode")
    end
    return nil
  end)
  
  if ok then
    return result
  end
  return nil
end

-- 設置 ascii_mode 狀態
local function set_ascii_mode(env, state)
  local ok, err = pcall(function()
    local context = env.engine.context
    if context and context.set_option then
      context:set_option("ascii_mode", state)
    end
  end)
  return ok
end

-- 保存當前 ascii_mode 狀態
local function save_ascii_mode_state(env)
  local ok, err = pcall(function()
    local current_state = get_ascii_mode(env)
    local schema_id = env.engine.schema.schema_id
    
    _G.liu_schema_switch_state.saved_ascii_mode = current_state
    _G.liu_schema_switch_state.saved_from_schema = schema_id
    _G.liu_schema_switch_state.saved_timestamp = os.time()
    _G.liu_schema_switch_state.pending_restore = true
    _G.liu_schema_switch_state.restore_attempted = false
  end)
  return ok
end

-- 檢查保存的狀態是否有效
local function is_saved_state_valid()
  local state = _G.liu_schema_switch_state
  
  if not state.pending_restore then
    return false
  end
  
  if state.saved_ascii_mode == nil then
    return false
  end
  
  if state.saved_timestamp then
    local elapsed = os.time() - state.saved_timestamp
    if elapsed > CONFIG.STATE_TIMEOUT then
      state.pending_restore = false
      state.saved_ascii_mode = nil
      return false
    end
  end
  
  return true
end

-- 恢復保存的 ascii_mode 狀態
local function restore_ascii_mode_state(env)
  if not is_saved_state_valid() then
    return false
  end
  
  local state = _G.liu_schema_switch_state
  
  -- 防止重複恢復
  if state.restore_attempted then
    return false
  end
  
  local ok = pcall(function()
    local saved_state = state.saved_ascii_mode
    set_ascii_mode(env, saved_state)
    state.pending_restore = false
    state.restore_attempted = true
  end)
  
  return ok
end

-- 清除保存的狀態
local function clear_saved_state()
  _G.liu_schema_switch_state.saved_ascii_mode = nil
  _G.liu_schema_switch_state.saved_from_schema = nil
  _G.liu_schema_switch_state.saved_timestamp = nil
  _G.liu_schema_switch_state.pending_restore = false
  _G.liu_schema_switch_state.restore_attempted = false
end

-- 主處理器函數
local function processor(key, env)
  local current_schema = env.engine.schema.schema_id
  
  -- 在 liur 方案中，每次按鍵都檢查是否需要恢復狀態
  -- 這是因為方案切換後，第一次按鍵時我們才有機會恢復狀態
  if current_schema == "liur" then
    local state = _G.liu_schema_switch_state
    if state.pending_restore and not state.restore_attempted then
      if state.saved_from_schema == "liur" then
        restore_ascii_mode_state(env)
      end
    end
  end
  
  -- 只處理按鍵按下事件
  if key:release() then
    return 2  -- kNoop
  end
  
  -- 檢查是否為 Ctrl+/ 按鍵
  if not is_ctrl_slash(key) then
    return 2  -- kNoop
  end
  
  -- 檢查是否為目標方案
  if not is_target_schema(current_schema) then
    return 2  -- kNoop
  end
  
  -- 從 liur 切換到 easy_en：保存狀態
  if current_schema == "liur" then
    save_ascii_mode_state(env)
  end
  
  -- 不攔截按鍵，讓 key_binder 處理實際的方案切換
  return 2  -- kNoop
end

-- 導出模組
return processor
