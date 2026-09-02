$ErrorActionPreference = "Stop"
$VpsIp = "5.42.97.60"
$Version = "0.31.3"
$Collectors = "cpu,logical_disk,memory,net,os,process,service,system,tcp"
$Msi = "$env:TEMP\windows_exporter.msi"
$Exe = "C:\Program Files\windows_exporter\windows_exporter.exe"
$Cfg = "C:\Program Files\windows_exporter\config.yaml"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

Write-Host "=== Download ==="
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/prometheus-community/windows_exporter/releases/download/v$Version/windows_exporter-$Version-amd64.msi" -OutFile $Msi

Write-Host "=== Stop old ==="
Stop-Service windows_exporter -Force -ErrorAction SilentlyContinue
Start-Sleep 2

Write-Host "=== Install ==="
$p = Start-Process msiexec.exe -ArgumentList "/i `"$Msi`" ENABLED_COLLECTORS=$Collectors LISTEN_PORT=9182 /qn /norestart" -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "msiexec failed: $($p.ExitCode)" }

Write-Host "=== Config ==="
@"
collectors:
  enabled: $Collectors
web:
  listen-address: ":9182"
"@ | Set-Content $Cfg -Encoding ASCII

sc.exe config windows_exporter binPath= "\"$Exe\" --config.file=\"$Cfg\" --collectors.enabled $Collectors" start= delayed-auto | Out-Null
sc.exe failure windows_exporter reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

Write-Host "=== Firewall ==="
Get-NetFirewallRule -DisplayName "windows_exporter" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow -RemoteAddress $VpsIp | Out-Null

Write-Host "=== Start ==="
Start-Service windows_exporter
Start-Sleep 3
$svc = Get-Service windows_exporter
if ($svc.Status -ne "Running") {
  Get-WinEvent -LogName Application -MaxEvents 10 | Where-Object { $_.Message -match "windows_exporter" } | Format-List TimeCreated, Message
  throw "Service is $($svc.Status)"
}

$r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:9182/metrics"
if ($r.StatusCode -ne 200) { throw "metrics HTTP $($r.StatusCode)" }

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" }).IPAddress -join ", "
Write-Host ""
Write-Host "OK. Service RUNNING, metrics 200"
Write-Host "Local IP: $ip"