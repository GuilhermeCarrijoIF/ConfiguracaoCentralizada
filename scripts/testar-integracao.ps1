param(
    [string]$DiretorioEvidencias = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evidencias')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$javaExecutable = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { (Get-Command java).Source }
$processos = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$resultados = [System.Collections.Generic.List[object]]::new()
$inicio = [DateTimeOffset]::Now
$clientes = @(
    @{ nome = 'cliente-vendas'; porta = 8081; mensagem = 'Bem-vindo ao sistema de Vendas - Ambiente DEV' },
    @{ nome = 'cliente-estoque'; porta = 8082; mensagem = 'Serviço de Estoque inicializado - Ambiente DEV' },
    @{ nome = 'cliente-relatorios'; porta = 8083; mensagem = 'Serviço de Relatórios em execução - Ambiente DEV' }
)

function Obter-Resposta([string]$Url) {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    $corpo = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    return @{ status = [int]$response.StatusCode; corpo = $corpo }
}

function Iniciar-Aplicacao([string]$Nome, [int]$Porta) {
    $jar = Join-Path $projectRoot "$Nome\target\$Nome-0.0.1-SNAPSHOT.jar"
    if (-not (Test-Path -LiteralPath $jar)) { throw "JAR ausente: $jar. Execute a compilação primeiro." }
    $processo = Start-Process -FilePath $javaExecutable -ArgumentList @('-jar', ('"' + $jar + '"')) -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $DiretorioEvidencias "$Nome.log") -RedirectStandardError (Join-Path $DiretorioEvidencias "$Nome.stderr.log")
    $processos.Add($processo)
    $limite = [DateTime]::UtcNow.AddSeconds(90)
    do {
        if ($processo.HasExited) { throw "$Nome encerrou durante a inicialização. Consulte os logs." }
        try {
            $saude = Obter-Resposta "http://localhost:$Porta/actuator/health"
            if (($saude.corpo | ConvertFrom-Json).status -eq 'UP') {
                Write-Host "$Nome iniciado na porta $Porta."
                return
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $limite)
    throw "Tempo esgotado ao iniciar $Nome. Consulte os logs."
}

function Registrar-Teste([string]$Nome, [string]$Url, [scriptblock]$Validar) {
    $registro = [ordered]@{ nome = $Nome; url = $Url; horario = [DateTimeOffset]::Now.ToString('o'); status_http = $null; resposta = $null; aprovado = $false; erro = $null }
    try {
        $resposta = Obter-Resposta $Url
        $registro.status_http = $resposta.status
        $registro.resposta = $resposta.corpo
        & $Validar $resposta.corpo
        if ($resposta.status -ne 200) { throw "HTTP inesperado: $($resposta.status)" }
        $registro.aprovado = $true
    } catch {
        $registro.erro = $_.Exception.Message
    }
    $resultados.Add([pscustomobject]$registro)
    Write-Host "$Nome : $($registro.aprovado) - HTTP $($registro.status_http)"
}

New-Item -ItemType Directory -Path $DiretorioEvidencias -Force | Out-Null
$erroExecucao = $null
try {
    $ocupadas = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 8888,8081,8082,8083 }
    if ($ocupadas) { throw 'Uma das portas 8888, 8081, 8082 ou 8083 está ocupada. Encerre as aplicações antes do teste.' }
    Iniciar-Aplicacao 'config-server' 8888
    foreach ($cliente in $clientes) { Iniciar-Aplicacao $cliente.nome $cliente.porta }

    foreach ($cliente in $clientes) {
        Registrar-Teste "Configuração $($cliente.nome)" "http://localhost:8888/$($cliente.nome)/dev" {
            param($corpo)
            $config = $corpo | ConvertFrom-Json
            if ($config.name -ne $cliente.nome -or $config.profiles -notcontains 'dev') { throw 'Nome da aplicação ou perfil incorreto.' }
            if (-not $config.version) { throw 'Versão Git ausente na resposta.' }
            $fonte = $config.propertySources | Where-Object { $_.name -match [regex]::Escape("$($cliente.nome)-dev.properties") } | Select-Object -First 1
            if (-not $fonte -or $fonte.name -notlike '*GuilhermeCarrijoIF/ConfiguracaoCentralizada*') { throw 'Configuração não veio do repositório indicado.' }
            if ($fonte.source.'mensagem.boasvindas' -cne $cliente.mensagem) { throw 'Mensagem remota diferente da esperada.' }
            if ([int]$fonte.source.'server.port' -ne $cliente.porta) { throw 'Porta remota diferente da esperada.' }
        }
        Registrar-Teste "Mensagem $($cliente.nome)" "http://localhost:$($cliente.porta)/mensagem" {
            param($corpo)
            if ($corpo -cne $cliente.mensagem) { throw "Mensagem diferente da esperada: $corpo" }
        }
        Registrar-Teste "Saúde $($cliente.nome)" "http://localhost:$($cliente.porta)/actuator/health" {
            param($corpo)
            if (($corpo | ConvertFrom-Json).status -ne 'UP') { throw 'Saúde diferente de UP.' }
        }
    }
    Registrar-Teste 'Saúde config-server' 'http://localhost:8888/actuator/health' {
        param($corpo)
        if (($corpo | ConvertFrom-Json).status -ne 'UP') { throw 'Saúde diferente de UP.' }
    }
} catch {
    $erroExecucao = $_.Exception.Message
} finally {
    foreach ($processo in $processos) {
        if (-not $processo.HasExited) { Stop-Process -Id $processo.Id -Force -ErrorAction SilentlyContinue }
        $processo.Dispose()
    }
    $registroFinal = [ordered]@{
        inicio = $inicio.ToString('o')
        fim = [DateTimeOffset]::Now.ToString('o')
        repositorio = 'https://github.com/GuilhermeCarrijoIF/ConfiguracaoCentralizada.git'
        perfil = 'dev'
        total = $resultados.Count
        aprovados = @($resultados | Where-Object { $_.aprovado }).Count
        erro_execucao = $erroExecucao
        testes = @($resultados.ToArray())
    }
    $registroFinal | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $DiretorioEvidencias 'testes.json') -Encoding UTF8
}
if ($erroExecucao) { throw $erroExecucao }
if ($registroFinal.total -ne 10 -or $registroFinal.aprovados -ne 10) { throw 'Um ou mais testes falharam. Consulte evidencias/testes.json.' }
Write-Host '10 de 10 testes aprovados. Evidências registradas e aplicações encerradas.'
