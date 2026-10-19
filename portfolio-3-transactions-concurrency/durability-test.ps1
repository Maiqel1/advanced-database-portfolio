$ErrorActionPreference = 'Continue'
$container = 'hospital-postgres'

function Invoke-Sql([string]$sql) {
    docker exec $container psql -U hospital_admin -d hospital -X -P pager=off -c $sql
}

function Wait-ForDatabase {
    for ($i = 0; $i -lt 60; $i++) {
        docker exec $container pg_isready -U hospital_admin -d hospital *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw 'The database did not come back within 60 seconds'
}

Write-Output '=== DURABILITY TEST: a committed row survives a crash, an uncommitted row does not'
Invoke-Sql "SET client_min_messages = warning; DROP TABLE IF EXISTS public.durability_test; CREATE TABLE public.durability_test (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text NOT NULL, written_at timestamp NOT NULL DEFAULT clock_timestamp())" | Out-Null

Write-Output ''
Write-Output '1. Session 1 begins a transaction, inserts a row, and waits without committing'
$job = Start-Job -ScriptBlock {
    docker exec hospital-postgres psql -U hospital_admin -d hospital -X -c "BEGIN; INSERT INTO public.durability_test (note) VALUES ('inserted but never committed'); SELECT pg_sleep(300);"
}
Start-Sleep -Seconds 3

Write-Output ''
Write-Output '2. Session 2 inserts a row and commits'
Invoke-Sql "INSERT INTO public.durability_test (note) VALUES ('committed just before the crash') RETURNING id, note"

Write-Output '3. Session 1 is still open, holding its uncommitted row'
Invoke-Sql "SELECT pid, state, xact_start IS NOT NULL AS in_transaction, left(query, 70) AS query FROM pg_stat_activity WHERE query LIKE 'BEGIN; INSERT INTO public.durability_test%'"

Write-Output '4. Rows other sessions can see before the crash'
Invoke-Sql "SELECT id, note FROM public.durability_test ORDER BY id"

$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Output '5. Crash: docker kill stops PostgreSQL instantly (SIGKILL), with no chance to shut down cleanly'
docker kill $container | Out-Null
Start-Sleep -Seconds 2
docker start $container | Out-Null
Wait-ForDatabase

Write-Output ''
Write-Output '6. Rows after the restart'
Invoke-Sql "SELECT id, note FROM public.durability_test ORDER BY id"

Write-Output '7. What PostgreSQL logged as it started up again'
docker logs --since $since $container 2>&1 |
    ForEach-Object { "$_" } |
    Select-String -Pattern 'interrupted|not properly shut down|automatic recovery|redo starts|redo done|ready to accept' |
    ForEach-Object { $_.Line }

Invoke-Sql "DROP TABLE public.durability_test" | Out-Null
Remove-Job -Job $job -Force
Write-Output ''
Write-Output 'Done.'
