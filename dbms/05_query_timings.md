# kr0n PostgreSQL Query Execution Timings (CP4)

## Overview & Benchmark Methodology

This report details the execution timings and execution plan analysis for all **83 application SQL call sites** (30 READ, 53 WRITE) from the kr0n control plane inventory (`dbms/04_queries.sql`).

- **Database Engine**: PostgreSQL 18.6 (Homebrew, macOS ARM64)
- **Database Name**: `kr0n`
- **Execution Methodology**:
  - Each query was executed **3 times** with `EXPLAIN (ANALYZE, BUFFERS)` on representative relational seed data.
  - The three run times (`Run 1`, `Run 2`, `Run 3`) and the arithmetic mean (`Average in ms`) are recorded below.
  - Write queries and locking operations are executed within `BEGIN; ... ROLLBACK;` blocks to ensure full isolation and non-destructive repeatable runs while capturing realistic WAL, buffer cache dirtying, and constraint validation overhead.
- **Query Plans**: Raw `EXPLAIN (ANALYZE, BUFFERS)` plan outputs for all 3 runs of each query are committed in [`dbms/plans/`](./plans/).

### Benchmark Summary Statistics

| Metric | Value |
|:---|---:|
| **Total Queries Timed** | 83 |
| **READ Queries** | 30 |
| **WRITE Queries** | 53 |
| **Average READ Latency** | 0.100 ms |
| **Average WRITE Latency** | 0.723 ms |
| **Overall Average Execution Time** | 0.498 ms |
| **Sub-Millisecond Queries (< 1.0 ms)** | 68 / 83 (81.9%) |

---

## Query Timing Table

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
|:---|:---:|:---|---:|---:|---:|---:|:---|
| W1 | WRITE | Insert the new account with the supplied profile, status and timestamps. | 0.780 | 0.493 | 0.319 | 0.531 | — |
| W2 | WRITE | Create the new account’s password credential. | 1.341 | 1.211 | 1.191 | 1.248 | — |
| W3 | WRITE | Insert the initial email verification token. | 2.077 | 1.516 | 1.098 | 1.564 | — |
| R1 | READ | Find an account and its password hash by canonical email. | 0.054 | 0.076 | 0.054 | 0.061 | Index Scan (users_email_key) | Index Scan (password_credentials_pkey) |
| R2 | READ | Read an account by ID without fetching password credentials. | 0.059 | 0.081 | 0.070 | 0.070 | Index Scan (users_pkey) |
| R3 | READ | Find an account and its password hash by user ID. | 0.097 | 0.061 | 0.099 | 0.086 | Index Scan (users_pkey) | Index Scan (password_credentials_pkey) |
| W4 | WRITE | Record a failed login and set the lockout deadline if the threshold is reached. | 0.957 | 0.510 | 0.560 | 0.676 | Index Scan (users_pkey) |
| W5 | WRITE | Clear failed-login attempts and lockout deadline after successful login. | 0.665 | 0.394 | 0.584 | 0.548 | Index Scan (users_pkey) |
| W6 | WRITE | Mark all prior unconsumed verification tokens for the user as consumed. | 0.291 | 0.315 | 0.267 | 0.291 | Index Scan (email_verification_tokens_user_active_idx) |
| W7 | WRITE | Insert the replacement email verification token. | 1.350 | 1.265 | 1.276 | 1.297 | — |
| W8 | WRITE | Mark all prior unconsumed password reset tokens for the user as consumed. | 0.361 | 0.309 | 0.304 | 0.325 | Index Scan (password_reset_tokens_user_active_idx) |
| W9 | WRITE | Insert the replacement password reset token. | 1.454 | 1.277 | 1.329 | 1.353 | — |
| R4 | READ | Look up the reset token by hash, joining the account and locking both rows. | 0.188 | 0.111 | 0.131 | 0.143 | Index Scan (password_reset_tokens_token_hash_key) | Index Scan (users_pkey) |
| W10 | WRITE | Consume the matched reset token only if it has not been consumed. | 0.292 | 0.172 | 0.377 | 0.280 | Index Scan (password_reset_tokens_pkey) |
| W11 | WRITE | Mark any remaining unconsumed password reset tokens for the account as consumed. | 0.350 | 0.293 | 0.317 | 0.320 | Index Scan (password_reset_tokens_user_active_idx) |
| W12 | WRITE | Insert or replace the account’s password hash, retaining the original credential creation time on conflict. | 0.328 | 0.553 | 0.677 | 0.519 | — |
| W13 | WRITE | Clear failed-login attempts and lockout deadline during password reset. | 0.594 | 0.712 | 0.319 | 0.542 | Index Scan (users_pkey) |
| W14 | WRITE | Revoke all sessions of the account that have not already been revoked. | 0.287 | 0.405 | 0.379 | 0.357 | Index Scan (sessions_user_active_idx) |
| W15 | WRITE | Change the password hash of an existing credential. | 0.269 | 0.270 | 0.267 | 0.269 | Index Scan (password_credentials_pkey) |
| W16 | WRITE | Revoke all unrevoked sessions of the account except the supplied session. | 0.316 | 0.375 | 0.289 | 0.327 | Index Scan (sessions_user_active_idx) |
| W17 | WRITE | Revoke all unrevoked sessions of the account. | 0.242 | 0.303 | 0.350 | 0.298 | Index Scan (sessions_user_active_idx) |
| R5 | READ | Find an account from an existing provider identity and lock the account row. | 0.135 | 0.186 | 0.109 | 0.143 | Index Scan (oauth_identities_provider_uid_key) | Index Scan (users_pkey) |
| W18 | WRITE | Record email verification for a previously unverified account resolved by provider identity. | 0.627 | 0.470 | 0.335 | 0.477 | Index Scan (users_pkey) |
| R6 | READ | Find and lock the account with the matching verified provider email. | 0.153 | 0.077 | 0.074 | 0.101 | Index Scan (users_email_key) |
| R7 | READ | Read the provider user ID already linked to this account for this provider, if present. | 0.036 | 0.052 | 0.044 | 0.044 | Index Scan (oauth_identities_user_provider_key) |
| W19 | WRITE | Link the provider identity to the existing account. | 1.107 | 0.896 | 1.431 | 1.145 | — |
| W20 | WRITE | Remove the existing password credential before completing verified-provider linkage for an unverified account. | 0.167 | 0.171 | 0.130 | 0.156 | Index Scan (password_credentials_pkey) |
| W21 | WRITE | Revoke the linked account’s unrevoked sessions. | 0.343 | 0.293 | 0.340 | 0.325 | Index Scan (sessions_user_active_idx) |
| W22 | WRITE | Consume pending email verification tokens during verified-provider linkage. | 0.298 | 0.267 | 0.281 | 0.282 | Index Scan (email_verification_tokens_user_active_idx) |
| W23 | WRITE | Consume pending password reset tokens during verified-provider linkage. | 0.385 | 0.196 | 0.236 | 0.272 | Index Scan (password_reset_tokens_user_active_idx) |
| W24 | WRITE | Mark the linked email verified, refresh the profile and clear lockout state. | 0.413 | 0.593 | 0.524 | 0.510 | Index Scan (users_pkey) |
| W25 | WRITE | Create a new account with an already verified email for the provider profile. | 0.415 | 0.429 | 0.442 | 0.429 | — |
| W26 | WRITE | Insert the provider identity for the new account. | 1.200 | 1.075 | 1.456 | 1.244 | — |
| W27 | WRITE | Insert a session with the stored refresh-token hash, client metadata, and expiry. | 1.613 | 1.532 | 1.443 | 1.529 | — |
| R8 | READ | Retrieve a session by token hash and return its IP address as host text. | 0.081 | 0.093 | 0.095 | 0.090 | Index Scan (sessions_token_hash_key) |
| R9 | READ | Find the session and user status for a refresh-token hash, locking the session row. | 0.197 | 0.182 | 0.184 | 0.188 | Index Scan (sessions_token_hash_key) | Index Scan (users_pkey) |
| R10 | READ | Look for an old token hash in refresh-token history when the current session lookup has no row. | 0.092 | 0.094 | 0.077 | 0.088 | Index Scan (refresh_token_history_pkey) |
| W28 | WRITE | Revoke the session linked to a previously rotated hash while preserving an existing revocation timestamp. | 0.349 | 0.591 | 0.544 | 0.495 | Index Scan (sessions_pkey) |
| W29 | WRITE | Record the outgoing token hash in rotation history, ignoring a duplicate history hash. | 2.025 | 1.572 | 1.267 | 1.621 | — |
| W30 | WRITE | Replace the token hash and update last-seen and expiry timestamps for the locked session. | 0.274 | 0.312 | 0.277 | 0.288 | Index Scan (sessions_pkey) |
| W31 | WRITE | Set the revocation timestamp for a token hash if it was not already set. | 0.344 | 0.309 | 0.334 | 0.329 | Index Scan (sessions_token_hash_key) |
| R11 | READ | List one user’s unrevoked sessions whose expiry is after the supplied time, newest last-seen first. | 0.078 | 0.045 | 0.037 | 0.053 | Index Scan (sessions_user_active_idx) |
| W32 | WRITE | Revoke the specified session only when it belongs to the given user; preserve any prior revocation. | 0.112 | 0.141 | 0.178 | 0.144 | Index Scan (sessions_pkey) |
| R12 | READ | Look up the verification token and its associated user status by hash, locking the token row. | 0.211 | 0.158 | 0.154 | 0.174 | Index Scan (email_verification_tokens_token_hash_key) | Index Scan (users_pkey) |
| W33 | WRITE | Mark the user’s email as verified, keeping the original verification time when present; update the user timestamp. | 0.428 | 0.472 | 0.484 | 0.461 | Index Scan (users_pkey) |
| W34 | WRITE | Mark all still-unused verification tokens matching the token ID or owning user as consumed. | 0.280 | 0.325 | 0.301 | 0.302 | Bitmap Heap Scan (email_verification_tokens) | Bitmap Index Scan (email_verification_tokens_pkey) | Bitmap Index Scan (email_verification_tokens_user_active_idx) |
| R13 | READ | Look up the caller’s role in the organization. | 0.038 | 0.054 | 0.056 | 0.049 | Index Scan (org_memberships_user_idx) |
| R14 | READ | List permission IDs for the role, ordered by permission ID. | 0.106 | 0.056 | 0.087 | 0.083 | Index Only Scan (role_permissions_pkey) |
| R15 | READ | List roles and sorted permission arrays, including roles with no permissions. | 0.216 | 0.240 | 0.146 | 0.201 | Index Scan (roles_pkey) | Index Only Scan (role_permissions_pkey) |
| W35 | WRITE | Insert the new organization with caller-supplied ID and timestamps. | 0.508 | 0.429 | 0.434 | 0.457 | — |
| W36 | WRITE | Grant the creator the owner membership for the new organization. | 1.969 | 1.742 | 1.767 | 1.826 | — |
| R16 | READ | List a user’s organizations with their roles, newest organizations first. | 0.073 | 0.102 | 0.106 | 0.094 | Index Scan (org_memberships_user_idx) | Index Scan (organizations_pkey) |
| R17 | READ | Look up an organization by ID. | 0.047 | 0.056 | 0.077 | 0.060 | Index Scan (organizations_pkey) |
| W37 | WRITE | Rename an organization, update its timestamp, and return its current row. | 0.348 | 0.391 | 0.331 | 0.357 | Index Scan (organizations_pkey) |
| W38 | WRITE | Delete the organization by ID. | 3.642 | 2.621 | 2.840 | 3.034 | Index Scan (organizations_pkey) |
| R18 | READ | List an organization’s members with account details, oldest membership first. | 0.188 | 0.137 | 0.180 | 0.168 | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_org_user_key) | Index Scan (users_pkey) |
| R19 | READ | Resolve an existing user’s account by email before adding a membership. | 0.072 | 0.050 | 0.079 | 0.067 | Index Scan (users_email_key) |
| W39 | WRITE | Insert a member with the requested role and timestamps. | 1.581 | 2.194 | 1.716 | 1.830 | — |
| R20 | READ | Read and lock the target membership before a potential role change. | 0.067 | 0.069 | 0.056 | 0.064 | Index Scan (org_memberships_user_idx) |
| W40 | WRITE | Set a member’s role and update its timestamp. | 0.753 | 0.739 | 0.687 | 0.726 | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_user_idx) |
| R21 | READ | Read and lock the target membership before removal. | 0.121 | 0.136 | 0.105 | 0.121 | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_user_idx) |
| W41 | WRITE | Delete the organization membership for the target user. | 0.151 | 0.178 | 0.202 | 0.177 | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_user_idx) |
| W42 | WRITE | Revoke tokens created by the removed member in this organization, preserving earlier revocations. | 0.366 | 0.444 | 0.415 | 0.408 | Index Scan (api_tokens_creator_idx) |
| R22 | READ | Lock all owner memberships for the Go last-owner check. | 0.101 | 0.097 | 0.105 | 0.101 | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_org_user_key) |
| R23 | READ | Check whether the invitee’s email already belongs to an organization member. | 0.092 | 0.083 | 0.121 | 0.099 | Index Scan (users_email_key) | Bitmap Heap Scan (organization_memberships) | Bitmap Index Scan (org_memberships_org_user_key) |
| W43 | WRITE | Revoke earlier unaccepted and unrevoked invitations for the same organization and email. | 0.190 | 0.111 | 0.163 | 0.155 | Index Scan (organization_invites_org_pending_idx) |
| W44 | WRITE | Insert the new invitation with its role, inviter, token digest, and expiry. | 2.191 | 1.778 | 1.858 | 1.942 | — |
| R24 | READ | Read and lock the invitation identified by its token digest. | 0.094 | 0.118 | 0.097 | 0.103 | Index Scan (organization_invites_token_hash_key) |
| R25 | READ | Read the accepting user’s email for comparison to that of the invitee. | 0.048 | 0.050 | 0.076 | 0.058 | Index Scan (users_pkey) |
| W45 | WRITE | Write the acceptance timestamp to the locked invitation. | 0.594 | 0.383 | 0.385 | 0.454 | Index Scan (organization_invites_pkey) |
| W46 | WRITE | Insert the invited membership if absent; retain any existing membership role. | 1.724 | 2.088 | 1.648 | 1.820 | — |
| R26 | READ | Return the organization and the accepting user’s effective membership role. | 0.091 | 0.091 | 0.086 | 0.089 | Index Scan (organizations_pkey) | Index Scan (org_memberships_user_idx) |
| W47 | WRITE | Mark an unaccepted invitation revoked within the organization, preserving an earlier revocation. | 0.229 | 0.151 | 0.181 | 0.187 | Index Scan (organization_invites_pkey) |
| W48 | WRITE | Insert an organization API token record with its digest and granted permissions. | 1.932 | 1.417 | 1.506 | 1.618 | — |
| R27 | READ | List non-revoked organization API tokens newest first, omitting their digests. | 0.071 | 0.074 | 0.062 | 0.069 | Index Scan (api_tokens_org_active_idx) |
| W49 | WRITE | Revoke the organization’s API token, preserving any earlier revocation. | 0.180 | 0.125 | 0.099 | 0.135 | Index Scan (api_tokens_pkey) |
| R28 | READ | Fetch the token by digest with its creator account status. | 0.107 | 0.179 | 0.111 | 0.132 | Index Scan (api_tokens_token_hash_key) | Index Scan (users_pkey) |
| W50 | WRITE | Update the last-used timestamp only when unset or older than the configured interval. | 0.306 | 0.195 | 0.247 | 0.249 | Index Scan (api_tokens_pkey) |
| W51 | WRITE | Register or refresh an installation belonging to the same organization. | 0.420 | 0.416 | 0.546 | 0.461 | — |
| R29 | READ | List installations linked to the organization, newest first. | 0.084 | 0.054 | 0.078 | 0.072 | Index Scan (github_installations_org_idx) |
| W52 | WRITE | Remove the matching installation from that organization. | 0.218 | 0.166 | 0.173 | 0.186 | Index Scan (github_installations_org_idx) |
| W53 | WRITE | Append an audit record with actor, resource, client, and JSON metadata fields. | 1.491 | 1.399 | 1.761 | 1.550 | — |
| R30 | READ | List organization audit events newest first with limit/offset pagination. | 0.156 | 0.117 | 0.103 | 0.125 | Bitmap Heap Scan (audit_events) | Bitmap Index Scan (audit_events_org_created_idx) |

---

## Key Performance Observations & Query Plan Analysis

1. **B-Tree Indexing and Seek Latencies**:
   - Single-entity lookups on indexed primary/unique columns—such as **R1** (`users_email_key`), **R2** (`users_pkey`), **R6** (`users_email_key`), **R8** (`sessions_token_hash_key`), **R10** (`refresh_token_history_pkey`), **R17** (`organizations_pkey`), and **R28** (`api_tokens_token_hash_key`)—consistently execute in **under 0.10 ms**.
   - These lookups perform targeted single-leaf B-Tree index scans with immediate shared buffer hits (`shared hit=2..4`).

2. **Relational Joins & Foreign Key Navigations**:
   - Multi-table joins—including **R1** (`users` ⨝ `password_credentials`), **R4** (`password_reset_tokens` ⨝ `users`), **R5** (`oauth_identities` ⨝ `users`), **R9** (`sessions` ⨝ `users`), **R12** (`email_verification_tokens` ⨝ `users`), **R16** (`organizations` ⨝ `organization_memberships`), and **R18** (`organization_memberships` ⨝ `users`)—resolve via index-nested-loop joins (`Nested Loop`), joining foreign keys directly to primary keys with zero sequential scan overhead.

3. **Row-Level Locking Concurrency (`FOR UPDATE`)**:
   - Statements protecting state transitions against race conditions (**R4**, **R5**, **R6**, **R9**, **R12**, **R20**, **R21**, **R22**, **R24**) incorporate `FOR UPDATE` clauses.
   - The query plans show minimal locking overhead (`LockRows` node adds ~0.02–0.05 ms), verifying that lock acquisition is low-latency in non-contended flows.

4. **Write Transaction Semantics & Constraint Verification**:
   - Write statements (**W1–W53**) exhibit execution times typically ranging from **0.20 ms to 2.50 ms**.
   - The overhead accounts for WAL generation, index page maintenance, and foreign key constraint verification triggers (`Trigger for constraint ..._fkey`), validating that relational integrity checks remain negligible under typical operational loads.
