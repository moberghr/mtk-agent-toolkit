#!/usr/bin/env bash
# Seeds a C# payment service, commits it, then leaves an uncommitted change in the
# working tree that adds a log line and wraps the ledger append in a try/catch.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src/Payments .claude
printf 'dotnet\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# payments

.NET 10 payment capture service. Every captured charge must have a matching ledger entry.

## Build & Test

    dotnet build
    dotnet test
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > src/Payments/PaymentService.cs <<'SRC'
namespace Acme.Payments;

public sealed class PaymentService(
    IPaymentGateway gateway,
    ILedger ledger,
    ILogger<PaymentService> logger)
{
    public async Task<PaymentResult> CaptureAsync(PaymentRequest request, CancellationToken ct)
    {
        var charge = await gateway.ChargeAsync(request.AccountId, request.Amount, request.Currency, ct);

        await ledger.AppendAsync(
            new LedgerEntry(request.AccountId, charge.Id, -request.Amount, request.Currency, DateTimeOffset.UtcNow),
            ct);

        return PaymentResult.Captured(charge.Id);
    }
}
SRC
git add -A
git commit -q -m "Add payment capture"

cat > src/Payments/PaymentService.cs <<'SRC'
namespace Acme.Payments;

public sealed class PaymentService(
    IPaymentGateway gateway,
    ILedger ledger,
    ILogger<PaymentService> logger)
{
    public async Task<PaymentResult> CaptureAsync(PaymentRequest request, CancellationToken ct)
    {
        logger.LogInformation("Capturing {Amount} {Currency} for {AccountId}", request.Amount, request.Currency, request.AccountId);

        var charge = await gateway.ChargeAsync(request.AccountId, request.Amount, request.Currency, ct);

        try
        {
            await ledger.AppendAsync(
                new LedgerEntry(request.AccountId, charge.Id, -request.Amount, request.Currency, DateTimeOffset.UtcNow),
                ct);
        }
        catch (Exception)
        {
            // the ledger service times out now and then; don't fail the payment over it
        }

        return PaymentResult.Captured(charge.Id);
    }
}
SRC
