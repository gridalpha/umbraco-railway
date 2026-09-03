using System.Net;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Data.SqlClient;
using Umbraco.Cms.Core;
using Umbraco.Cms.Core.Services;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Wait for the configured SQL Server catalog to exist before Umbraco boots.
//
// Railway has no service dependency ordering, so on a first (template) deploy the
// database container is still starting and its `umbraco` catalog does not exist yet.
// Umbraco does not retry: it would fall through to its interactive installer and serve
// that on a public URL. Opening a real connection to the configured catalog is the exact
// gate we need — it fails while SQL Server is down *and* while the database is missing.
// ---------------------------------------------------------------------------
string? connectionString = builder.Configuration.GetConnectionString("umbracoDbDSN");
string? providerName = builder.Configuration.GetConnectionString("umbracoDbDSN_ProviderName");

if (!string.IsNullOrWhiteSpace(connectionString) &&
    string.Equals(providerName, "Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase))
{
    int attempts = int.TryParse(Environment.GetEnvironmentVariable("DB_WAIT_ATTEMPTS"), out int a) ? a : 60;
    int delaySeconds = int.TryParse(Environment.GetEnvironmentVariable("DB_WAIT_DELAY_SECONDS"), out int d) ? d : 5;

    for (int attempt = 1; attempt <= attempts; attempt++)
    {
        try
        {
            using var probe = new SqlConnection(connectionString);
            probe.Open();
            Console.WriteLine($"[startup] Database reachable after {attempt} attempt(s).");
            break;
        }
        catch (Exception ex) when (attempt < attempts)
        {
            Console.WriteLine($"[startup] Database not ready (attempt {attempt}/{attempts}): {ex.Message}");
            Thread.Sleep(TimeSpan.FromSeconds(delaySeconds));
        }
    }
}

builder.CreateUmbracoBuilder()
    .AddBackOffice()
    .AddWebsite()
    .AddDeliveryApi()
    .AddComposers()
    .Build();

// ---------------------------------------------------------------------------
// Persist ASP.NET Core Data Protection keys.
//
// Umbraco calls AddDataProtection() with no persistence, which on a Linux container
// falls back to an ephemeral in-memory key ring: every redeploy invalidates backoffice
// sessions, antiforgery tokens and any protected payload. Registered after the Umbraco
// builder so this configuration wins.
// ---------------------------------------------------------------------------
string? keysPath = Environment.GetEnvironmentVariable("DATAPROTECTION_KEYS_PATH");
if (!string.IsNullOrWhiteSpace(keysPath))
{
    Directory.CreateDirectory(keysPath);
    builder.Services
        .AddDataProtection()
        .PersistKeysToFileSystem(new DirectoryInfo(keysPath))
        .SetApplicationName("UmbracoCms");
}

WebApplication app = builder.Build();

// ---------------------------------------------------------------------------
// Railway's edge terminates TLS and rewrites X-Forwarded-For / X-Forwarded-Proto,
// overwriting anything the client sent, so the *leftmost* entry of each is trustworthy
// with no trust list. ASP.NET Core's ForwardedHeaders middleware reads right-to-left and
// would land on the edge's own rotating address instead, so read the headers directly.
// Set TRUST_FORWARDED_HEADERS=false when this app is reached without a reverse proxy.
// ---------------------------------------------------------------------------
if (!string.Equals(Environment.GetEnvironmentVariable("TRUST_FORWARDED_HEADERS"), "false", StringComparison.OrdinalIgnoreCase))
{
    app.Use(async (context, next) =>
    {
        string? proto = context.Request.Headers["X-Forwarded-Proto"].FirstOrDefault();
        if (!string.IsNullOrEmpty(proto))
        {
            string scheme = proto.Split(',')[0].Trim();
            if (scheme is "http" or "https")
            {
                context.Request.Scheme = scheme;
            }
        }

        string? forwardedFor = context.Request.Headers["X-Forwarded-For"].FirstOrDefault();
        if (!string.IsNullOrEmpty(forwardedFor))
        {
            string candidate = forwardedFor.Split(',')[0].Trim();
            if (IPAddress.TryParse(candidate, out IPAddress? ip))
            {
                context.Connection.RemoteIpAddress = ip;
            }
            else if (IPEndPoint.TryParse(candidate, out IPEndPoint? endpoint))
            {
                context.Connection.RemoteIpAddress = endpoint.Address;
            }
        }

        await next();
    });
}

// Anonymous liveness/readiness probe that touches the database: the runtime only reaches
// `Run` once Umbraco has connected and the schema is installed. Terminal, so it never
// enters Umbraco's own routing.
app.Map("/healthz", branch => branch.Run(async context =>
{
    IRuntimeState state = context.RequestServices.GetRequiredService<IRuntimeState>();
    bool healthy = state.Level == RuntimeLevel.Run;

    context.Response.StatusCode = healthy ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable;
    context.Response.ContentType = "text/plain";
    await context.Response.WriteAsync(healthy ? "OK" : $"Umbraco runtime level: {state.Level}");
}));

await app.BootUmbracoAsync();

app.UseUmbraco()
    .WithMiddleware(u =>
    {
        u.UseBackOffice();
        u.UseWebsite();
    })
    .WithEndpoints(u =>
    {
        u.UseBackOfficeEndpoints();
        u.UseWebsiteEndpoints();
    });

await app.RunAsync();
