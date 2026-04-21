param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Domain
)

$ErrorActionPreference = 'Stop'

$Router = if ($env:ROUTER_SSH) { $env:ROUTER_SSH } else { 'root@192.168.2.1' }

ssh -o StrictHostKeyChecking=no $Router "/usr/local/bin/xray-remove-direct $Domain"
