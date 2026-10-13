<#
    curl_check.ps1 —— 用真实 curl.exe 验证 auto-eportal.sh 里每一条 curl 命令的
    参数写法（--data-urlencode / -G / -c -b Cookie / -i 等）是否真的能把
    queryString 完整送到服务器。

    运行：  powershell -ExecutionPolicy Bypass -File test\curl_check.ps1
    说明：  会启动 test/mock_eportal.py 假门户，跑完自动关掉。
            -o /dev/null 在 Windows 上写作 NUL，其余参数与路由器脚本一致。
#>

$ErrorActionPreference = 'Stop'
$port = 18090
$base = "http://127.0.0.1:$port"
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
$cookie = Join-Path $env:TEMP 'auto-eportal-curl-test.cookie'
$script:failed = 0

function Ok($name)  { Write-Host "  PASS  $name" }
function Bad($name) { Write-Host "  FAIL  $name"; $script:failed++ }
function Check($name, $cond, $detail = '') {
    if ($cond) { Ok $name } else { Bad "$name  $detail" }
}

# ---------------------------------------------------------------- 启动假门户
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) { Write-Host '找不到 python，无法运行测试'; exit 2 }

$mock = Start-Process -FilePath $python.Source `
    -ArgumentList @((Join-Path $PSScriptRoot 'mock_eportal.py'), '--port', $port) `
    -PassThru -WindowStyle Hidden

try {
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $null = & curl.exe -s -m 2 "$base/_state"
            $ready = $true; break
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { Write-Host '假门户启动失败'; exit 2 }

    Remove-Item $cookie -ErrorAction SilentlyContinue

    Write-Host '=========== 1. 探测（curl -i，判断是否被劫持）==========='
    $probe = (& curl.exe -s -m 8 -i -A $ua "$base/generate_204") -join "`n"
    Check '探测返回 302' ($probe -match 'HTTP/1\.1 302') $probe.Substring(0, [Math]::Min(60, $probe.Length))

    $portal = [regex]::Match($probe, 'http://\S*eportal/index\.jsp\S*').Value.TrimEnd("'", '"')
    Check '解析到认证页地址' ($portal -ne '') $portal
    $qs = $portal.Split('?', 2)[1]
    Check 'queryString 含 wlanuserip' ($qs -like '*wlanuserip=*')
    Write-Host ("  queryString 长度 = {0}" -f $qs.Length)

    Write-Host '=========== 2. 先访问认证页拿 Cookie ============'
    $null = & curl.exe -s -m 10 -c $cookie -b $cookie -A $ua -o NUL $portal
    $jar = if (Test-Path $cookie) { Get-Content $cookie -Raw } else { '' }
    Check 'Cookie 落盘且含 JSESSIONID' ($jar -match 'JSESSIONID')

    Write-Host '=========== 3. 门户配置（-G --data-urlencode 拼到 URL 上）==========='
    $page = (& curl.exe -s -m 10 -A $ua -c $cookie -b $cookie -H "Referer: $portal" `
        -G --data-urlencode "queryString=$qs" "$base/eportal/InterFace.do?method=page") -join ''
    Check 'method=page 返回 JSON 配置' ($page -match '"service"') $page

    Write-Host '=========== 4. 登录（--data-urlencode，queryString 在表单）==========='
    $resp = (& curl.exe -s -m 15 -c $cookie -b $cookie -A $ua `
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' `
        -H 'X-Requested-With: XMLHttpRequest' `
        -H 'Accept: application/json, text/javascript, */*; q=0.01' `
        -H "Referer: $portal" `
        -X POST "$base/eportal/InterFace.do?method=login" `
        --data-urlencode 'userId=2021000000' `
        --data-urlencode 'password=123456' `
        --data-urlencode 'service=' `
        --data-urlencode "queryString=$qs" `
        --data 'operatorPwd=' `
        --data 'operatorUserId=' `
        --data-urlencode 'validcode=' `
        --data 'passwordEncrypt=false') -join ''
    Write-Host "  原始返回: $resp"
    Check '服务器返回 result=success' ($resp -match '"result":\s*"success"') $resp

    $state = (& curl.exe -s -m 5 "$base/_state") | ConvertFrom-Json
    Check '服务器状态已认证' ($state.authed -eq $true)
    Check '只发起了 1 次登录' ($state.login_count -eq 1) "实际 $($state.login_count)"
    Check 'queryString 长度未被截断' `
        ($state.last_query_string.Length -eq $qs.Length) `
        "发出 $($qs.Length) / 收到 $($state.last_query_string.Length)"
    Check 'queryString 内容完全一致' ($state.last_query_string -eq $qs)
    Check 'userId 正确送达' ($state.last_form.userId -eq '2021000000')
    Check '空 service 参数存在' ($state.last_form.PSObject.Properties.Name -contains 'service')

    Write-Host '=========== 5. 认证后探测应为 204 ============'
    $code = (& curl.exe -s -m 8 -o NUL -w '%{http_code}' -A $ua "$base/generate_204") -join ''
    Check '已在线时探测返回 204' ($code -eq '204') "实际 $code"

    Write-Host '=========== 6. 旧版接口 userV2.do ============'
    $resp2 = (& curl.exe -s -m 15 -c $cookie -b $cookie -A $ua `
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' `
        -H 'X-Requested-With: XMLHttpRequest' `
        -H "Referer: $portal" `
        -X POST "$base/eportal/userV2.do?method=login&param=true&$qs" `
        --data-urlencode 'username=2021000000' `
        --data-urlencode 'pwd=123456') -join ''
    Write-Host "  原始返回: $resp2"
    Check '旧版接口返回 success' ($resp2 -match '"result": ?"success"') $resp2

    Write-Host '=========== 7. 密码错误时的应答 ============'
    $null = & curl.exe -s -m 5 -X POST "$base/eportal/InterFace.do?method=logout" 2>$null
    $resp3 = (& curl.exe -s -m 15 -A $ua `
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' `
        -X POST "$base/eportal/InterFace.do?method=login" `
        --data-urlencode 'userId=2021000000' `
        --data-urlencode 'password=wrong' `
        --data-urlencode 'service=' `
        --data-urlencode "queryString=$qs") -join ''
    Write-Host "  原始返回: $resp3"
    Check '密码错误时返回 fail + message' `
        (($resp3 -match '"result": ?"fail"') -and ($resp3 -match 'message')) $resp3
}
finally {
    if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
    Remove-Item $cookie -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "==== 结果：$script:failed 项失败 ===="
exit $(if ($script:failed -eq 0) { 0 } else { 1 })
