param (
    [string]$ContainerName
)
$runnerOs = $Env:RUNNER_OS ?? "Linux"

if ($runnerOs -eq "Linux") {
    Write-Output "Killing Docker container $ContainerName"
    docker kill $ContainerName

    Write-Output "Removing Docker container $ContainerName"
    docker rm $ContainerName
}
elseif ($runnerOs -eq "Windows") {
    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? "Debian"

    Write-Output "Removing WSL Docker container $ContainerName"
    wsl.exe --distribution $wslDistribution --user root -- bash -c "docker rm --force ${ContainerName} 2>/dev/null || true"
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}
