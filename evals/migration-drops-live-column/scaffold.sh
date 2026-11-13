#!/usr/bin/env bash
# Seeds an EF Core customer service, commits it, then commits a change on a feature branch
# that splits Customer.FullName into FirstName/LastName (entity, endpoints, welcome email
# and a migration that adds the two columns, copies the data across and drops FullName),
# alongside an optional phone number, a last-name search endpoint and doc updates.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src/Customers/Migrations src/Customers/Notifications docs .claude
printf 'dotnet\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# customers

.NET 10 customer service: ASP.NET Core minimal APIs, EF Core 10 on PostgreSQL.

## Build & Test

    dotnet build
    dotnet test

## Deployment

Runs as three instances behind a load balancer. The release pipeline applies pending
EF Core migrations, then replaces the instances one at a time.
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > src/Customers/Customer.cs <<'SRC'
namespace Acme.Customers;

public sealed class Customer
{
    public Guid Id { get; set; }
    public string FullName { get; set; } = "";
    public string Email { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}
SRC

cat > src/Customers/CustomersDbContext.cs <<'SRC'
using Microsoft.EntityFrameworkCore;

namespace Acme.Customers;

public sealed class CustomersDbContext(DbContextOptions<CustomersDbContext> options) : DbContext(options)
{
    public DbSet<Customer> Customers => Set<Customer>();
}
SRC

cat > src/Customers/CustomerEndpoints.cs <<'SRC'
using Microsoft.EntityFrameworkCore;

namespace Acme.Customers;

public static class CustomerEndpoints
{
    public sealed record CustomerDto(Guid Id, string Name, string Email);
    public sealed record CreateCustomer(string Name, string Email);

    public static void MapCustomerEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/customers/{id:guid}", async (Guid id, CustomersDbContext db, CancellationToken ct) =>
        {
            var customer = await db.Customers
                .Where(c => c.Id == id)
                .Select(c => new CustomerDto(c.Id, c.FullName, c.Email))
                .SingleOrDefaultAsync(ct);
            return customer is null ? Results.NotFound() : Results.Ok(customer);
        });

        app.MapPost("/customers", async (CreateCustomer request, CustomersDbContext db, CancellationToken ct) =>
        {
            var customer = new Customer
            {
                Id = Guid.NewGuid(),
                FullName = request.Name,
                Email = request.Email,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            db.Customers.Add(customer);
            await db.SaveChangesAsync(ct);
            return Results.Created($"/customers/{customer.Id}", new CustomerDto(customer.Id, customer.FullName, customer.Email));
        });
    }
}
SRC

cat > src/Customers/Migrations/20260115090000_Initial.cs <<'SRC'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Acme.Customers.Migrations;

public partial class Initial : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "Customers",
            columns: table => new
            {
                Id = table.Column<Guid>(nullable: false),
                FullName = table.Column<string>(maxLength: 200, nullable: false),
                Email = table.Column<string>(maxLength: 320, nullable: false),
                CreatedAt = table.Column<DateTimeOffset>(nullable: false),
            },
            constraints: table => table.PrimaryKey("PK_Customers", x => x.Id));
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "Customers");
    }
}
SRC
cat > src/Customers/Notifications/WelcomeEmail.cs <<'SRC'
namespace Acme.Customers.Notifications;

public static class WelcomeEmail
{
    public static string Subject => "Welcome to Acme";

    public static string Body(Customer customer) =>
        $"Dear {customer.FullName},\n\nyour Acme account is ready. Sign in with {customer.Email}.\n";
}
SRC

cat > docs/api.md <<'DOC'
# Customers API

## GET /customers/{id}

Returns `{ "id", "name", "email" }`, or 404.

## POST /customers

Body `{ "name", "email" }`. Returns 201 with the created customer.
DOC

cat > CHANGELOG.md <<'DOC'
# Changelog

## 1.4.0

- Customers API: create and fetch customers.
DOC
git add -A
git commit -q -m "Add customer service"

# The change under review, committed on a feature branch.
git checkout -q -b customer-name-split

cat > src/Customers/Customer.cs <<'SRC'
namespace Acme.Customers;

public sealed class Customer
{
    public Guid Id { get; set; }
    public string FirstName { get; set; } = "";
    public string LastName { get; set; } = "";
    public string Email { get; set; } = "";
    public string? Phone { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}
SRC

cat > src/Customers/CustomersDbContext.cs <<'SRC'
using Microsoft.EntityFrameworkCore;

namespace Acme.Customers;

public sealed class CustomersDbContext(DbContextOptions<CustomersDbContext> options) : DbContext(options)
{
    public DbSet<Customer> Customers => Set<Customer>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var customer = modelBuilder.Entity<Customer>();
        customer.Property(c => c.FirstName).HasMaxLength(100);
        customer.Property(c => c.LastName).HasMaxLength(100);
        customer.Property(c => c.Email).HasMaxLength(320);
        customer.Property(c => c.Phone).HasMaxLength(32);
        customer.HasIndex(c => c.LastName);
    }
}
SRC

cat > src/Customers/CustomerEndpoints.cs <<'SRC'
using Microsoft.EntityFrameworkCore;

namespace Acme.Customers;

public static class CustomerEndpoints
{
    public sealed record CustomerDto(Guid Id, string FirstName, string LastName, string Email, string? Phone);
    public sealed record CreateCustomer(string FirstName, string LastName, string Email, string? Phone);

    private const int MaxSearchResults = 50;

    public static void MapCustomerEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/customers/{id:guid}", async (Guid id, CustomersDbContext db, CancellationToken ct) =>
        {
            var customer = await db.Customers
                .Where(c => c.Id == id)
                .Select(c => new CustomerDto(c.Id, c.FirstName, c.LastName, c.Email, c.Phone))
                .SingleOrDefaultAsync(ct);
            return customer is null ? Results.NotFound() : Results.Ok(customer);
        });

        app.MapGet("/customers", async (string lastName, CustomersDbContext db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(lastName))
            {
                return Results.BadRequest("lastName is required");
            }

            var customers = await db.Customers
                .Where(c => c.LastName == lastName.Trim())
                .OrderBy(c => c.FirstName)
                .Take(MaxSearchResults)
                .Select(c => new CustomerDto(c.Id, c.FirstName, c.LastName, c.Email, c.Phone))
                .ToListAsync(ct);
            return Results.Ok(customers);
        });

        app.MapPost("/customers", async (CreateCustomer request, CustomersDbContext db, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(request.FirstName) || string.IsNullOrWhiteSpace(request.Email))
            {
                return Results.BadRequest("firstName and email are required");
            }

            var customer = new Customer
            {
                Id = Guid.NewGuid(),
                FirstName = request.FirstName.Trim(),
                LastName = request.LastName.Trim(),
                Email = request.Email.Trim(),
                Phone = string.IsNullOrWhiteSpace(request.Phone) ? null : request.Phone.Trim(),
                CreatedAt = DateTimeOffset.UtcNow,
            };
            db.Customers.Add(customer);
            await db.SaveChangesAsync(ct);
            return Results.Created($"/customers/{customer.Id}",
                new CustomerDto(customer.Id, customer.FirstName, customer.LastName, customer.Email, customer.Phone));
        });
    }
}
SRC

cat > src/Customers/Notifications/WelcomeEmail.cs <<'SRC'
namespace Acme.Customers.Notifications;

public static class WelcomeEmail
{
    public static string Subject => "Welcome to Acme";

    public static string Body(Customer customer) =>
        $"Hi {customer.FirstName},\n\nyour Acme account is ready. Sign in with {customer.Email}.\n";
}
SRC

cat > src/Customers/Migrations/20261110120000_SplitCustomerName.cs <<'SRC'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Acme.Customers.Migrations;

public partial class SplitCustomerName : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<string>(
            name: "FirstName", table: "Customers", maxLength: 100, nullable: false, defaultValue: "");
        migrationBuilder.AddColumn<string>(
            name: "LastName", table: "Customers", maxLength: 100, nullable: false, defaultValue: "");
        migrationBuilder.AddColumn<string>(
            name: "Phone", table: "Customers", maxLength: 32, nullable: true);

        migrationBuilder.Sql("""
            UPDATE "Customers"
            SET "FirstName" = split_part("FullName", ' ', 1),
                "LastName"  = trim(substr("FullName", length(split_part("FullName", ' ', 1)) + 1));
            """);

        migrationBuilder.DropColumn(name: "FullName", table: "Customers");

        migrationBuilder.CreateIndex(
            name: "IX_Customers_LastName", table: "Customers", column: "LastName");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropIndex(name: "IX_Customers_LastName", table: "Customers");
        migrationBuilder.AddColumn<string>(
            name: "FullName", table: "Customers", maxLength: 200, nullable: false, defaultValue: "");
        migrationBuilder.DropColumn(name: "Phone", table: "Customers");
        migrationBuilder.DropColumn(name: "FirstName", table: "Customers");
        migrationBuilder.DropColumn(name: "LastName", table: "Customers");
    }
}
SRC

cat > docs/api.md <<'DOC'
# Customers API

## GET /customers/{id}

Returns `{ "id", "firstName", "lastName", "email", "phone" }`, or 404. `phone` may be null.

## GET /customers?lastName=

Customers with that exact last name, ordered by first name, at most 50.

## POST /customers

Body `{ "firstName", "lastName", "email", "phone" }`; `firstName` and `email` are required.
Returns 201 with the created customer.
DOC

cat > CHANGELOG.md <<'DOC'
# Changelog

## 1.5.0

- Customers have a first and last name instead of a single name field.
- Optional phone number on customers.
- `GET /customers?lastName=` search.

## 1.4.0

- Customers API: create and fetch customers.
DOC
git add -A
git commit -q -m "Split customer name, add phone and last-name search"
