param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$InitScript = "",
    [string]$RegistryLoginServer = "index.docker.io",
    [string]$RegistryUser,
    [string]$RegistryPass
)

$dockerImage = "postgres:18"
$password = [guid]::NewGuid().ToString("n")
Write-Output "::add-mask::$password"
$userName = "postgres"
$databaseName = "postgres"
$ipAddress = "127.0.0.1"
$port = 5432
$runnerOs = $Env:RUNNER_OS ?? "Linux"

$env:PGPASSWORD = $password

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distribution,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [switch]$CheckExitCode
    )

    wsl.exe --distribution $Distribution --user root -- bash -c $Command

    if ($CheckExitCode -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed with exit code $LASTEXITCODE`: $Command"
    }
}

if ($runnerOs -eq "Linux") {
    Write-Output "Running Postgres in container $($ContainerName) using Docker"

    docker run --name "$($ContainerName)" -d -p "$($port):$($port)" -e POSTGRES_PASSWORD=$password -e POSTGRES_USER=$userName -e POSTGRES_DB=$databaseName $dockerImage -c max_prepared_transactions=10
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running Postgres in container $($ContainerName) using WSL"

    # psql is not in PATH on Windows
    $Env:PATH = $Env:PATH + ';' + $Env:PGBIN

    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? "Debian"

    # Constrain the WSL2 VM (memory) and keep it from being shut down when idle, so that Docker
    # and the container are not torn down between this setup step and the test step. Only write
    # when the file is absent so local development configurations are left untouched.
    $wslConfigPath = Join-Path $Env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $wslConfigPath)) {
        $wslMemory = $Env:WSL_MEMORY_OVERRIDE ?? "3GB"
        Write-Output "Writing $wslConfigPath (memory=$wslMemory) to constrain the WSL2 VM"
        Set-Content -Path $wslConfigPath -Value "[wsl2]`nmemory=$wslMemory`nvmIdleTimeout=-1" -Encoding ASCII
    }

    Write-Output "::group::Preparing WSL ($wslDistribution)"

    wsl.exe --set-default-version 2 | Out-Null

    # Install the distribution if it is not already registered.
    $installedDistributions = ((wsl.exe --list --quiet) -replace "`0", "") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    if ($installedDistributions -notcontains $wslDistribution) {
        Write-Output "Installing $wslDistribution in WSL"
        wsl.exe --install $wslDistribution --web-download --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $wslDistribution in WSL"
        }
    }
    else {
        Write-Output "$wslDistribution is already installed"
    }

    # Ensure Docker is installed inside the WSL distribution.
    Write-Output "Ensuring Docker is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v docker >/dev/null 2>&1 || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes docker.io; }"

    # Start the Docker daemon via systemd when available, otherwise via the SysV service.
    Write-Output "Starting Docker daemon inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker info >/dev/null 2>&1 || { if [ -d /run/systemd/system ]; then systemctl start docker; else service docker start; fi; }"

    # Optionally log in to the container registry to avoid rate limits when pulling.
    if ($registryUser -and $registryPass) {
        Write-Output "::add-mask::$registryPass"
        Write-Output "Logging in to $RegistryLoginServer inside WSL"
        $loginCommand = "docker login --username '$RegistryUser' --password-stdin '$RegistryLoginServer'"
        $registryPass | wsl.exe --distribution $wslDistribution --user root -- bash -c $loginCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Docker registry login inside WSL failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Output "Using anonymous credentials"
    }

    # Keep the WSL instance alive for the rest of the job. WSL terminates an instance when no
    # processes remain under its init (PID 2); a plain background process (e.g. sleep) does not
    # prevent this, but a D-Bus session bus launched through `wsl --exec` does. vmIdleTimeout
    # above covers the VM-level idle timeout; this covers the separate instance-level shutdown.
    # See https://github.com/microsoft/WSL/issues/10138 and
    # https://blog.lecoteauverdoyant.co.uk/articles/wsl-keep-alive.html
    Write-Output "Starting a D-Bus session to keep the WSL instance alive for the job"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v dbus-launch >/dev/null 2>&1 || { apt-get update && apt-get install -y dbus; }"
    wsl.exe --distribution $wslDistribution --user root --exec /usr/bin/dbus-launch true
    if ($LASTEXITCODE -ne 0) {
        Write-Output "::warning::dbus-launch keep-alive returned exit code $LASTEXITCODE"
    }

    Write-Output "::endgroup::"

    Write-Output "::group::Starting PostgreSQL container"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker run --name $ContainerName --detach --restart unless-stopped --publish ${port}:${port} -e POSTGRES_PASSWORD='$password' -e POSTGRES_USER='$userName' -e POSTGRES_DB='$databaseName' $dockerImage -c max_prepared_transactions=10"
    Invoke-Wsl -Distribution $wslDistribution -Command "docker ps --filter name=$ContainerName"

    # Determine the WSL VM IPv4 address so that Windows can reach the published port.
    $wslIp = ((wsl.exe --distribution $wslDistribution --user root -- hostname -I) -replace "`0", "").Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1

    if (-not $wslIp) {
        throw "Could not determine the WSL IPv4 address"
    }

    $ipAddress = $wslIp
    Write-Output "WSL address: $ipAddress"

    Write-Output "::endgroup::"
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}

Write-Output "::group::Testing connection"

for ($i = 0; $i -lt 24; $i++) { ## 2 minute timeout
    Write-Output "Checking for PostgreSQL connectivity $($i+1)/30..."
    psql --host $ipAddress --username=$userName --list > $null
    if ($?) {
        Write-Output "Connection successful"
      break;
    }
    sleep 5
  }

Write-Output "::endgroup::"

# write the connection string to the specified environment variable
"$($ConnectionStringName)=User ID=$($userName);Password=$($password);Host=$($ipAddress);Port=$($port);Database=$($databaseName);" >> $Env:GITHUB_ENV

if ($InitScript) {
    Write-Output "::group::Running init script $InitScript"

    $script = Get-Content $InitScript -Raw
    psql --host $ipAddress --username=$userName --command $script
    if (-not $?) {
        Write-Output "Script execution failed"
      exit 1
    }

    Write-Output "::endgroup::"
}
