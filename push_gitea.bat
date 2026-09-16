@echo off
REM ========================================
REM Safex Gitea 推送脚本
REM 推送 docs/、main/ 和 readme.md 到 Gitea
REM 仓库: http://192.168.5.16:8080/wzh/safex_lua_code
REM ========================================

echo [Gitea Push] 开始推送 docs/、main/ 和 readme.md 到 Gitea...

REM 切换到 orphan 分支
git checkout gitea-docs-main 2>nul
if errorlevel 1 (
    echo [Gitea Push] 创建新的 orphan 分支...
    git checkout --orphan gitea-docs-main
)

REM 清空索引并只添加 docs、main 和 readme.md
git rm -r --cached . -f >nul 2>&1
git add docs/ main/ readme.md

REM 提交
git commit -m "chore: 更新 docs/、main/ 和 readme.md ✨" 2>nul
if errorlevel 1 (
    echo [Gitea Push] 没有变更，跳过提交
    git checkout main 2>nul
    goto :eof
)

REM 推送到 Gitea
git push gitea gitea-docs-main:main

REM 切回 main 分支
git checkout main 2>nul

echo [Gitea Push] 推送完成！
echo [Gitea Push] 仓库地址: http://192.168.5.16:8080/wzh/safex_lua_code
