@echo off
rem 《时局图》RPG —— 一键跑全部测试
rem
rem 分两步，两步都过了才算数：
rem   1. Node 导出器  —— 验剧本数据本身（81 场景 / 2193 拍 / 31 条扩写）
rem   2. Godot 测试   —— 验游戏读到的这份数据、条件求值、存档
rem 中间隔着 JSON 序列化与 Godot 的解析，所以两步不能互相替代。
rem
rem 用法：双击本文件，或在命令行里跑 跑测试.bat

setlocal
cd /d "%~dp0"

set GODOT=%~dp0..\godot\Godot_v4.7.2-stable_win64_console.exe
if not exist "%GODOT%" set GODOT=D:\claude\godot\Godot_v4.7.2-stable_win64_console.exe

echo.
echo ══════════════════════════════════════════════
echo   第一步 / 二   Node 导出器（剧本数据）
echo ══════════════════════════════════════════════
node tools\export_story.js
if errorlevel 1 (
  echo.
  echo   导出器没过 —— 后面不用跑了。
  exit /b 1
)

echo.
echo ══════════════════════════════════════════════
echo   第二步 / 二   Godot 测试
echo ══════════════════════════════════════════════
"%GODOT%" --headless --path . res://tests/test_main.tscn
if errorlevel 1 exit /b 1

echo.
echo   全部通过。
exit /b 0
