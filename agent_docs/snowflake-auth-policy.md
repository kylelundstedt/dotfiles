# Snowflake Authentication Policy: Restricting Programmatic Access

Discovery and migration plan for tightening client-type controls on the `ak97040.west-us-2.azure` Snowflake account. Drafted 2026-04-20.

## 1. Security Concern

Snowflake's default behavior is that any user with SAML SSO access — i.e., any user provisioned through the JumpCloud SCIM integration — can authenticate to the account through **any client type**, not just Snowsight. The same SSO flow that signs them into the web UI also works for:

- `snow` (Snowflake CLI)
- SnowSQL
- Python / JDBC / ODBC / .NET / Go / Node.js connectors
- Any third-party tool that supports `authenticator=externalbrowser` (dbt, sqlmesh, dlt, BI tools, AI agents, etc.)

This means **any user can connect Claude Code (or any other AI agent / scripting tool) to Snowflake without admin help**:

1. `uv tool install snowflake-cli`
2. Add `~/.snowflake/connections.toml` with `authenticator = "externalbrowser"`
3. Run `snow connection test` — browser pops, SSO completes, Claude can now query Snowflake as that user with all of their grants

The agent inherits whatever role the user has. Snowflake's audit log attributes everything to the human user; there is no server-side distinction between "human running query" and "agent running query." With SSO token caching enabled (`ALLOW_ID_TOKEN = TRUE` at account level), the agent can run queries for ~4 hours after the user's last SSO without re-authenticating.

The implicit assumption that "SSO users only have Snowsight access" was incorrect. SAML2 integrations grant identity, not interface restrictions.

## 2. How a User Gets Access (Today)

Required: any IndustryVault employee with a SAML-provisioned Snowflake account.

```bash
# 1. Install Snowflake CLI (no admin involvement)
uv tool install snowflake-cli

# 2. Configure connection
cat > ~/.snowflake/connections.toml <<'EOF'
["ak97040"]
account = "ak97040.west-us-2.azure"
user = "user@industryvault.com"
authenticator = "externalbrowser"
client_store_temporary_credential = true
EOF

snow connection set-default ak97040

# 3. Run a query — browser pops once for SSO, then any client (snow, dbt,
#    Claude Code via subprocess, sqlmesh, etc.) can hit Snowflake using
#    the cached token for ~4 hours.
snow sql -q "SHOW DATABASES"
```

That's it. No ticket. No approval. No audit trail of "user wired up programmatic access."

The `ALLOW_ID_TOKEN = TRUE` setting we enabled today expanded the cache window from "every query" to "every 4 hours." Without that flag the user gets prompted to SSO on every query, but the access pattern itself is unchanged — they still have programmatic access.

## 3. Proposed Fix: Authentication Policies

Snowflake's [Authentication Policies](https://docs.snowflake.com/en/user-guide/authentication-policies) let you restrict which `CLIENT_TYPES` users can connect through. The plan: deny programmatic clients by default, exempt the small set of users who legitimately need them.

```sql
-- Default for everyone: web UI only
CREATE AUTHENTICATION POLICY snowsight_only
  CLIENT_TYPES = ('SNOWFLAKE_UI')
  COMMENT = 'Default for all users: Snowsight web UI only';

-- Power users / devs: UI + drivers + CLI
CREATE AUTHENTICATION POLICY developer_full_access
  CLIENT_TYPES = ('SNOWFLAKE_UI', 'DRIVERS', 'SNOWFLAKE_CLI', 'SNOWSQL')
  COMMENT = 'Devs who need programmatic access from local workstations';

-- Service accounts: drivers only, no UI, programmatic auth only
CREATE AUTHENTICATION POLICY service_account_access
  CLIENT_TYPES = ('DRIVERS')
  AUTHENTICATION_METHODS = ('PASSWORD', 'KEYPAIR', 'OAUTH', 'PROGRAMMATIC_ACCESS_TOKEN')
  COMMENT = 'Service accounts: programmatic only, no SSO/UI';

-- Apply restrictive default at the account level
ALTER ACCOUNT SET AUTHENTICATION POLICY snowsight_only;

-- Per-user exemptions (user-level overrides account-level)
ALTER USER "AKILLINGER@INDUSTRYVAULT.COM" SET AUTHENTICATION POLICY developer_full_access;
-- ... etc, one per exempted user
```

### Important Caveats from the Snowflake Docs

- **CLIENT_TYPES is a "best-effort" control, not a security boundary.** Snowflake explicitly says it should not be used as the sole control. The User-Agent header that determines client type can be spoofed in some configurations.
- **Does NOT restrict the Snowflake REST API.** A determined user can hit `https://<account>.snowflakecomputing.com/api/v2/statements/` directly with an OAuth token regardless of CLIENT_TYPES policy. Network policies are required for that.
- **Granularity limit.** `DRIVERS` is a single bucket covering JDBC, ODBC, Python connector, .NET, Go, Node.js, etc. You cannot allow Python connector but block JDBC; either all drivers are allowed or none are.

This is a **friction control + visibility tool**, not a hard barrier. It will absolutely stop "anyone with SSO can wire up Claude in 30 seconds," but it would not stop a motivated user determined to exfiltrate data.

## 4. Impact of the Proposed Policies

Discovery query against `SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY` for the trailing 90 days revealed:

### Account-wide client distribution (90 days)

| Client                                              |    Logins | Distinct Users | Notes                        |
| --------------------------------------------------- | --------: | -------------: | ---------------------------- |
| `JDBC_DRIVER`                                       | 2,050,432 |              4 | Mostly Fivetran              |
| `PYTHON_DRIVER`                                     |   606,955 |              9 | GitHub Actions + power users |
| `DOTNET_DRIVER`                                     |    92,362 |              5 | ADF service accounts         |
| `GO_DRIVER`                                         |     6,413 |              4 | ADF service accounts         |
| `SNOWFLAKE_UI`                                      |     2,309 |             49 | The actual humans            |
| Other (SQL_API, SQL_ALCHEMY, JS, Snowpark, SnowSQL) |      <100 |              4 | Long tail                    |

**Key observation:** 49 distinct humans use Snowsight, but only ~15 distinct users use programmatic clients — and the bulk of those are service accounts. The proposed policy affects a small, identifiable population.

### Service Accounts — must be exempted (would break critical pipelines)

| User                               | Auth Method | Client    | 90-day Logins | Purpose                                           |
| ---------------------------------- | ----------- | --------- | ------------: | ------------------------------------------------- |
| `CMG_FIVETRAN_USER`                | PASSWORD    | JDBC      |     1,822,073 | Fivetran ETL                                      |
| `GITHUB_ACTIONS_SERVICE_ACCOUNT`   | RSA_KEYPAIR | Python    |       545,422 | CI/CD (6,942 distinct IPs)                        |
| `CMG_DOMO_SERVICE_ACCOUNT`         | PASSWORD    | JDBC      |       228,342 | Domo BI                                           |
| `ADF_DEV_USER`                     | PAT         | .NET / Go |        20,035 | Azure Data Factory dev                            |
| `ADF_PROD_USER`                    | PAT         | .NET / Go |        23,502 | Azure Data Factory prod                           |
| `ADF_QA_USER`                      | PAT         | .NET      |        19,525 | Azure Data Factory QA                             |
| `ADF_UAT_USER`                     | PAT         | .NET / Go |        35,465 | Azure Data Factory UAT                            |
| `DLT_PROD_USER`                    | PAT         | Python    |         1,317 | dlt pipeline                                      |
| `DOMO_DEV_USER` / `DOMO_PROD_USER` | PAT         | JDBC      |            17 | Domo dev/prod                                     |
| `CMG_REPORTING_SERVICE_ACCOUNT`    | PASSWORD    | Python    |           523 | Internal reporting (505 distinct IPs — see below) |

### Human Users — currently using programmatic clients

| User                           | Pattern                                            | Action                                          |
| ------------------------------ | -------------------------------------------------- | ----------------------------------------------- |
| `AKILLINGER@INDUSTRYVAULT.COM` | RSA_KEYPAIR, 59,386 Python logins, 30 IPs          | **Heavy power user — must exempt**              |
| `CJMBAGWUH@INDUSTRYVAULT.COM`  | RSA_KEYPAIR, 154 Python logins                     | Active dev — exempt                             |
| `DKILLINGER@INDUSTRYVAULT.COM` | RSA_KEYPAIR, 3 Python logins                       | Light use — exempt                              |
| `KQUEEN@CMGFI.COM`             | Python + Go + JS + Snowpark, mix of OAuth/SAML/PAT | Active power user — exempt                      |
| `KLUNDSTEDT@INDUSTRYVAULT.COM` | Python via SAML SSO + ID_TOKEN                     | Exempt (today's testing + ongoing dev)          |
| `PRAMESH@CMGFI.COM`            | 2 SAML Python logins, last 2026-03-19              | **Verify still needed**                         |
| `DANILO.LIMA@CMGFI.COM`        | 1 .NET login, 2026-03-31                           | **Verify — may be transient**                   |
| `HPARK@CMGFI.COM`              | 1 SnowSQL login, 2026-02-05                        | **Verify — likely transient**                   |
| `CHARLIER@CMGFI.COM`           | 21 SQL_API calls via OAuth                         | **Verify still needed**                         |
| `JKODIBAGKAR@CMGFI.COM`        | SQL_ALCHEMY via SAML                               | Already dropped (`DROPPED_USER$...`), no action |

### Things to Address Independently of This Policy Change

These were surfaced by the discovery query and warrant separate attention:

1. **`CMG_REPORTING_SERVICE_ACCOUNT` has 505 distinct IPs with PASSWORD authentication.** Strongly suggests a shared password used by many people or scripts. Recommend rotating to RSA keypair tied to a single deployment, or splitting into multiple service accounts per consumer.
2. **Three service accounts still use PASSWORD auth** (`CMG_FIVETRAN_USER`, `CMG_DOMO_SERVICE_ACCOUNT`, `CMG_REPORTING_SERVICE_ACCOUNT`). Recommend migration to RSA keypair or PAT for stronger auth and easier rotation.
3. **MFA enforcement policy `CMG_ENFORE_PASSWORD_MFA` exists in `CMG_MASTER.PUBLIC` but is not attached to any user or to the account.** It enforces MFA enrollment but is currently inert.
4. **Two more orphan auth policies** in `CMG_ADHOC_DEVELOP_AKILLINGER_DB.PUBLIC` (`JUMPCLOUD_AUTHTENTICATION_POLICY`, `REQUIRE_MFA_AUTHENTICATION_POLICY`) — created but not attached. Worth deleting or moving to `CMG_MASTER` and properly applying.

## 5. Recommended Migration Plan

### Phase 0 — Pre-Work (1 week before)

- [ ] Email engineering / data team: announce the change, explain the rationale (preventing inadvertent agent connections), and ask anyone using a driver / CLI to reply.
- [ ] Verify the questionable users from the table above (PRAMESH, DANILO.LIMA, HPARK, CHARLIER) — confirm whether they still need driver access.
- [ ] Inventory any tools / dashboards owned by the team that might use SSO + driver auth: jumphost notebooks, ad-hoc Python scripts on shared servers, BI tool configurations.
- [ ] Decide on policy for new users: default is `snowsight_only`; exemption requires a ticket / approval.

### Phase 1 — Create Policies (no impact)

```sql
USE ROLE ACCOUNTADMIN;
USE DATABASE CMG_MASTER;
USE SCHEMA PUBLIC;

CREATE OR REPLACE AUTHENTICATION POLICY snowsight_only
  CLIENT_TYPES = ('SNOWFLAKE_UI')
  COMMENT = 'Default for all users: Snowsight web UI only';

CREATE OR REPLACE AUTHENTICATION POLICY developer_full_access
  CLIENT_TYPES = ('SNOWFLAKE_UI', 'DRIVERS', 'SNOWFLAKE_CLI', 'SNOWSQL')
  COMMENT = 'Devs who need programmatic access from local workstations';

CREATE OR REPLACE AUTHENTICATION POLICY service_account_access
  CLIENT_TYPES = ('DRIVERS')
  AUTHENTICATION_METHODS = ('PASSWORD', 'KEYPAIR', 'OAUTH', 'PROGRAMMATIC_ACCESS_TOKEN')
  COMMENT = 'Service accounts: programmatic only, no SSO/UI';
```

Verify with `SHOW AUTHENTICATION POLICIES IN SCHEMA CMG_MASTER.PUBLIC;` and `DESC AUTHENTICATION POLICY ...`.

### Phase 2 — Apply Exemptions First (no breakage)

User-level policies override the account-level default, so attaching exemptions before flipping the default means nothing breaks.

```sql
-- Service accounts
ALTER USER "ADF_DEV_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "ADF_PROD_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "ADF_QA_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "ADF_UAT_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "CMG_DOMO_SERVICE_ACCOUNT" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "CMG_FIVETRAN_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "CMG_REPORTING_SERVICE_ACCOUNT" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "DLT_PROD_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "DOMO_DEV_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "DOMO_PROD_USER" SET AUTHENTICATION POLICY service_account_access;
ALTER USER "GITHUB_ACTIONS_SERVICE_ACCOUNT" SET AUTHENTICATION POLICY service_account_access;

-- Power users
ALTER USER "AKILLINGER@INDUSTRYVAULT.COM" SET AUTHENTICATION POLICY developer_full_access;
ALTER USER "CJMBAGWUH@INDUSTRYVAULT.COM" SET AUTHENTICATION POLICY developer_full_access;
ALTER USER "DKILLINGER@INDUSTRYVAULT.COM" SET AUTHENTICATION POLICY developer_full_access;
ALTER USER "KQUEEN@CMGFI.COM" SET AUTHENTICATION POLICY developer_full_access;
ALTER USER "KLUNDSTEDT@INDUSTRYVAULT.COM" SET AUTHENTICATION POLICY developer_full_access;

-- Conditionally (after Phase 0 verification)
-- ALTER USER "PRAMESH@CMGFI.COM" SET AUTHENTICATION POLICY developer_full_access;
-- ALTER USER "DANILO.LIMA@CMGFI.COM" SET AUTHENTICATION POLICY developer_full_access;
-- ALTER USER "HPARK@CMGFI.COM" SET AUTHENTICATION POLICY developer_full_access;
-- ALTER USER "CHARLIER@CMGFI.COM" SET AUTHENTICATION POLICY developer_full_access;
```

Verify each with:

```sql
SHOW PARAMETERS LIKE 'AUTHENTICATION_POLICY' IN USER "AKILLINGER@INDUSTRYVAULT.COM";
```

### Phase 3 — Smoke Test on a Single Restricted User (low-risk validation)

Pick a colleague who only uses Snowsight (not on the exemption list) and confirm:

1. They can still access Snowsight normally (no change).
2. If they try `snow sql` from a CLI, it fails with a policy error.

If validation passes, proceed.

### Phase 4 — Apply Account-Level Default

Recommend doing this **late in the day** (after business hours, before the next day's pipelines run) so any unexpected breakage has overnight to be caught.

```sql
ALTER ACCOUNT SET AUTHENTICATION POLICY snowsight_only;

-- Verify
SHOW PARAMETERS LIKE 'AUTHENTICATION_POLICY' IN ACCOUNT;
```

### Phase 5 — Monitor & Iterate (1 week post-rollout)

```sql
-- Watch for failed logins by client type / user
SELECT
    USER_NAME,
    REPORTED_CLIENT_TYPE,
    ERROR_CODE,
    ERROR_MESSAGE,
    COUNT(*) AS failure_count,
    MAX(EVENT_TIMESTAMP) AS last_failure
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE EVENT_TIMESTAMP >= DATEADD(day, -1, CURRENT_TIMESTAMP())
  AND IS_SUCCESS = 'NO'
  AND ERROR_MESSAGE ILIKE '%authentication policy%'
GROUP BY ALL
ORDER BY failure_count DESC;
```

Add exemptions reactively as legitimate use cases emerge. After a week of clean logs, this becomes the steady state.

### Rollback

If anything goes catastrophically wrong:

```sql
ALTER ACCOUNT UNSET AUTHENTICATION POLICY;
```

Reverts immediately to default (all clients allowed). The created policies stay in place; only the attachment is removed.

## Open Questions for the Next Session

- Who should own this policy long-term? ACCOUNTADMIN is too broad; a SECURITYADMIN-style role for managing auth policies might be appropriate.
- Should service accounts also be restricted to specific IPs via NETWORK_POLICY? GitHub Actions is hard (6,942 IPs from GH-hosted runners) but Fivetran / ADF / Domo have known IP ranges.
- Should we pair this with a user-level audit script (cron) that flags any user attempting non-allowed clients?
- Should new SCIM-provisioned users automatically get the restrictive default? They will, since account-level is the default — but worth confirming SCIM doesn't override it on user creation.
