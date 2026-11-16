# Database normalization: kr0n control plane

This document traces the normalization of the kr0n control plane database from an unnormalized representation (UNF) through First Normal Form (1NF), Second Normal Form (2NF), Third Normal Form (3NF), and Boyce-Codd Normal Form (BCNF).

---

## 1. Domain overview

The kr0n control plane manages authentication, authorization (RBAC), multi-tenant organizations, API tokens, user sessions, and audit logging for distributed cloud services.

The primary domain entities include:
- **Users**: Registered accounts with email, profile details, and account status.
- **Password credentials**: Password hashes kept separate from core user profiles for security isolation.
- **OAuth identities**: Federated identities linking external providers (GitHub, Google) to internal users.
- **Organizations**: Tenant workspaces grouping team members and resources.
- **Roles and permissions**: Role-based access control structures (`owner`, `admin`, `member`) and fine-grained permissions (`org:read`, `project:create`, etc.).
- **Organization memberships**: Association between users, organizations, and assigned roles.
- **Sessions & refresh tokens**: Active user sessions, IP addresses, client metadata, and rotation tracking.
- **API tokens**: Organization-scoped personal access tokens with permission subsets.
- **Audit events**: Append-only audit logs tracking administrative and security actions.

---

## 2. Unnormalized form (UNF)

In an unnormalized design, all application data resides in a single, monolithic "universal table" or document structure. Attributes contain multi-valued repeating groups, nested structures, and mixed concerns across users, organizations, roles, and permissions.

### Monolithic unnormalized schema

```text
UNF_USER_SYSTEM(
    user_id,
    user_email,
    user_display_name,
    user_status,
    password_hash,
    oauth_providers { provider_name, provider_user_id },
    organizations {
        org_id,
        org_name,
        org_slug,
        org_role_id,
        org_role_name,
        org_role_description,
        role_permissions { permission_id, permission_description }
    },
    sessions {
        session_id,
        session_token_hash,
        session_ip,
        session_user_agent,
        session_expires_at
    },
    api_tokens {
        token_id,
        token_name,
        token_prefix,
        token_hash,
        token_permissions
    }
)
```

### Sample unnormalized record

| user_id | user_email | user_display_name | oauth_providers | organizations | sessions |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `usr_01` | `alice@example.com` | Alice Doe | `[{github, 1024}, {google, 8821}]` | `[{org_01, "Acme Corp", "acme", "admin", "Admin", "Admin access", ["org:read", "project:create"]}]` | `[{sess_101, tok_a1, 192.168.1.1}, {sess_102, tok_a2, 10.0.0.5}]` |

### Problems in UNF
1. **Repeating groups and nested data**: Attributes like `oauth_providers`, `organizations`, `role_permissions`, and `sessions` contain lists of values, violating relational atomicity.
2. **Variable row sizes**: A user with five organizations and ten sessions requires complex internal parsing or arbitrary arrays.
3. **Severe data redundancy**: The same organization name, role description, and permission definitions are duplicated for every user who joins an organization.

---

## 3. First normal form (1NF)

### 1NF rules
A relation is in **First Normal Form (1NF)** if:
1. Every attribute value is **atomic** (indivisible single value per cell; no repeating groups, arrays, or nested objects).
2. All entries in a column are of the same domain/type.
3. Each column has a unique name.
4. The order of rows and columns does not matter.
5. A unique primary key exists to identify each row.

### Transformation from UNF to 1NF

To convert the UNF structure into 1NF, we eliminate all repeating groups by expanding them into separate rows. Every cell now holds a single atomic value.

For the core identity and organization access domain, the flattened relation becomes:

```text
FLAT_MEMBERSHIP_ACCESS(
    user_id,
    user_email,
    user_display_name,
    password_hash,
    oauth_provider,
    oauth_provider_uid,
    org_id,
    org_name,
    org_slug,
    role_id,
    role_name,
    role_description,
    permission_id,
    permission_description
)
```

### Sample 1NF tabular data

| user_id | user_email | user_display_name | oauth_provider | oauth_provider_uid | org_id | org_name | org_slug | role_id | role_name | permission_id | permission_desc |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `usr_01` | `alice@kr0n.dev` | Alice | `github` | `gh_123` | `org_01` | Acme | `acme` | `admin` | Admin | `org:read` | View org |
| `usr_01` | `alice@kr0n.dev` | Alice | `github` | `gh_123` | `org_01` | Acme | `acme` | `admin` | Admin | `project:create` | Create proj |
| `usr_01` | `alice@kr0n.dev` | Alice | `google` | `gg_456` | `org_01` | Acme | `acme` | `admin` | Admin | `org:read` | View org |
| `usr_01` | `alice@kr0n.dev` | Alice | `google` | `gg_456` | `org_01` | Acme | `acme` | `admin` | Admin | `project:create` | Create proj |
| `usr_02` | `bob@kr0n.dev` | Bob | `github` | `gh_789` | `org_01` | Acme | `acme` | `member` | Member | `org:read` | View org |

### Composite primary key in 1NF
To uniquely identify a row in `FLAT_MEMBERSHIP_ACCESS`, the composite primary key must include:
$$\text{Primary Key} = \{ \text{user\_id}, \text{oauth\_provider}, \text{org\_id}, \text{permission\_id} \}$$

### Functional dependencies in 1NF
- $\{\text{user\_id}\} \to \text{user\_email}, \text{user\_display\_name}, \text{password\_hash}$
- $\{\text{user\_id}, \text{oauth\_provider}\} \to \text{oauth\_provider\_uid}$
- $\{\text{org\_id}\} \to \text{org\_name}, \text{org\_slug}$
- $\{\text{role\_id}\} \to \text{role\_name}, \text{role\_description}$
- $\{\text{permission\_id}\} \to \text{permission\_description}$
- $\{\text{user\_id}, \text{org\_id}\} \to \text{role\_id}$

### Anomalies present in 1NF
1. **Insertion anomaly**:
   - You cannot create a permission (`audit:read`) without assigning it to an existing user who belongs to an organization and has an OAuth provider.
   - You cannot register a new organization until at least one user is assigned a role and permission in that organization.
2. **Update anomaly**:
   - If the description for `role_id = 'admin'` changes, you must update every row where `admin` appears. If one row is missed, data becomes inconsistent.
   - Updating `org_name` for `Acme` requires updating every row across all users and permissions in that organization.
3. **Deletion anomaly**:
   - If user `usr_02` leaves `org_01`, and `usr_02` was the only member with the `member` role, the system loses the definition of the `member` role and its associated permissions.

---

## 4. Second normal form (2NF)

### 2NF rules
A relation is in **Second Normal Form (2NF)** if:
1. It is in **1NF**.
2. **No non-prime attribute is partially dependent on any candidate key**. Every non-key attribute must depend on the *entire* candidate key, not a proper subset of it.

> [!NOTE]
> A table with a single-attribute primary key is automatically in 2NF once it satisfies 1NF, because no partial subset of a single key exists.

### Identification of partial dependencies

In `FLAT_MEMBERSHIP_ACCESS`, the primary key is composite:
$$\text{PK} = \{ \text{user\_id}, \text{oauth\_provider}, \text{org\_id}, \text{permission\_id} \}$$

Notice that several non-prime attributes depend only on a fraction of this composite key:
- **Partial dependency 1**: $\{\text{user\_id}\} \to \text{user\_email}, \text{user\_display\_name}, \text{password\_hash}$ (depends only on `user_id`, not on `org_id` or `permission_id`).
- **Partial dependency 2**: $\{\text{user\_id}, \text{oauth\_provider}\} \to \text{oauth\_provider\_uid}$ (depends on user and provider, not on organization or permission).
- **Partial dependency 3**: $\{\text{org\_id}\} \to \text{org\_name}, \text{org\_slug}$ (depends only on `org_id`).
- **Partial dependency 4**: $\{\text{permission\_id}\} \to \text{permission\_description}$ (depends only on `permission_id`).
- **Partial dependency 5**: $\{\text{user\_id}, \text{org\_id}\} \to \text{role\_id}, \text{role\_name}, \text{role\_description}$ (depends only on `user_id` and `org_id`).

### Decomposition into 2NF relations

To achieve 2NF, we split `FLAT_MEMBERSHIP_ACCESS` into separate relations based on each determinant of partial dependencies.

#### 1. `users_2nf`
- **Attributes**: `user_id`, `email`, `display_name`, `password_hash`
- **Primary key**: `user_id`
- **Dependencies**: `user_id -> email, display_name, password_hash` (Full dependency on candidate key).

#### 2. `user_oauth_identities_2nf`
- **Attributes**: `user_id`, `provider`, `provider_user_id`
- **Primary key**: `{user_id, provider}`
- **Dependencies**: `{user_id, provider} -> provider_user_id` (Full dependency on composite key).

#### 3. `organizations_2nf`
- **Attributes**: `org_id`, `name`, `slug`
- **Primary key**: `org_id`
- **Dependencies**: `org_id -> name, slug` (Full dependency on candidate key).

#### 4. `permissions_2nf`
- **Attributes**: `permission_id`, `description`
- **Primary key**: `permission_id`
- **Dependencies**: `permission_id -> description` (Full dependency on candidate key).

#### 5. `role_permissions_2nf`
- **Attributes**: `role_id`, `permission_id`
- **Primary key**: `{role_id, permission_id}`
- **Dependencies**: Association table; key consists only of prime attributes.

#### 6. `organization_memberships_2nf`
- **Attributes**: `org_id`, `user_id`, `role_id`, `role_name`, `role_description`
- **Primary key**: `{org_id, user_id}`
- **Dependencies**:
  - `{org_id, user_id} -> role_id`
  - `{org_id, user_id} -> role_name`
  - `{org_id, user_id} -> role_description`

### Remaining anomalies in 2NF (transitive dependencies)
Notice `organization_memberships_2nf`:
- The composite key is `{org_id, user_id}`.
- `{org_id, user_id} -> role_id`
- But `role_id -> role_name, role_description`.
- Therefore, `{org_id, user_id} -> role_name` is a **transitive dependency** through `role_id`.

If we update `role_description` for the `admin` role, we still have to update multiple rows in `organization_memberships_2nf`.

---

## 5. Third normal form (3NF)

### 3NF rules
A relation is in **Third Normal Form (3NF)** if:
1. It is in **2NF**.
2. **No non-prime attribute is transitively dependent on any candidate key**.
3. Formally: For every non-trivial functional dependency $X \to Y$, either:
   - $X$ is a **superkey**, OR
   - $Y$ is a **prime attribute** (a member of any candidate key).

### Identification of transitive dependencies

In `organization_memberships_2nf`:
- Candidate key: `{org_id, user_id}`
- Functional dependencies:
  - $\{\text{org\_id}, \text{user\_id}\} \to \text{role\_id}$
  - $\{\text{role\_id}\} \to \text{role\_name}, \text{role\_description}$
- Here, `role_id` is not a superkey of `organization_memberships_2nf`, and neither `role_name` nor `role_description` is a prime attribute.
- This is a transitive dependency: $\{\text{org\_id}, \text{user\_id}\} \to \text{role\_id} \to \{\text{role\_name}, \text{role\_description}\}$.

Similarly, in `users_2nf`:
- `password_hash` has a 1-to-1 relationship with `user_id`, but OAuth-only users (users logging in via GitHub or Google) do not have a password. Storing `password_hash` in `users` causes `NULL` values and couples identity management with credential mechanisms. Isolating credentials into a dedicated `password_credentials` table removes partial nullability.

### Decomposition into 3NF relations

To resolve transitive dependencies, extract the intermediate determinant and its dependent attributes into their own relation.

#### 1. Extract `roles` table
Extract `role_id -> role_name, role_description`:
```text
roles(
    id,             -- Primary Key
    name,
    description,
    created_at,
    updated_at
)
```

#### 2. Refined `organization_memberships` table
Now `organization_memberships` only retains the foreign key reference:
```text
organization_memberships(
    id,              -- Primary Key (UUID)
    organization_id, -- Foreign Key -> organizations(id)
    user_id,         -- Foreign Key -> users(id)
    role_id,         -- Foreign Key -> roles(id)
    created_at,
    updated_at
)
```
- Primary Key: `id` (or candidate key `{organization_id, user_id}`).
- Determinant: `{organization_id, user_id} -> role_id`.
- Since `{organization_id, user_id}` is a candidate key (superkey), the dependency satisfies 3NF.

#### 3. Normalized `users` and `password_credentials`
```text
users(
    id,              -- Primary Key
    email,           -- Candidate Key
    email_verified_at,
    display_name,
    avatar_url,
    status,
    failed_login_attempts,
    locked_until,
    created_at,
    updated_at
)

password_credentials(
    user_id,         -- Primary Key & Foreign Key -> users(id)
    password_hash,
    created_at,
    updated_at
)
```

#### 4. Normalized `oauth_identities`
```text
oauth_identities(
    id,                -- Primary Key
    user_id,           -- Foreign Key -> users(id)
    provider,
    provider_user_id,
    created_at,
    updated_at
)
```

#### 5. Normalized `sessions`
```text
sessions(
    id,                -- Primary Key
    user_id,           -- Foreign Key -> users(id)
    token_hash,        -- Candidate Key
    user_agent,
    ip_address,
    expires_at,
    revoked_at,
    created_at,
    last_seen_at
)
```

At this stage, all non-prime attributes depend directly and non-transitively on candidate keys.

---

## 6. Boyce-Codd normal form (BCNF)

### BCNF rules
**Boyce-Codd Normal Form (BCNF)** is a stricter version of 3NF.
A relation is in BCNF if and only if:
> For every non-trivial functional dependency $X \to Y$, $X$ must be a **superkey**.

In 3NF, the condition allows $Y$ to be a prime attribute even if $X$ is not a superkey. BCNF eliminates this exception: every determinant must be a candidate key or superkey.

### Evaluation of kr0n tables against BCNF

Let us evaluate the relations in kr0n's data model to verify whether each satisfies BCNF:

#### 1. `users`
- **Candidate keys**:
  1. `id`
  2. `email` (enforced via `UNIQUE CONSTRAINT users_email_key`)
- **Functional dependencies**:
  - `id -> email, email_verified_at, display_name, avatar_url, status, ...`
  - `email -> id, email_verified_at, display_name, avatar_url, status, ...`
- **Evaluation**: Both determinants `id` and `email` are candidate keys (superkeys).
- **Result**: `users` is in **BCNF**.

#### 2. `organizations`
- **Candidate keys**:
  1. `id`
  2. `slug` (enforced via `UNIQUE CONSTRAINT organizations_slug_key`)
- **Functional dependencies**:
  - `id -> name, slug, created_at, updated_at`
  - `slug -> id, name, created_at, updated_at`
- **Evaluation**: Both determinants `id` and `slug` are superkeys.
- **Result**: `organizations` is in **BCNF**.

#### 3. `oauth_identities`
- **Candidate keys**:
  1. `id`
  2. `{provider, provider_user_id}` (enforced via `UNIQUE(provider, provider_user_id)`)
  3. `{user_id, provider}` (enforced via `UNIQUE(user_id, provider)`)
- **Functional dependencies**:
  - `id -> user_id, provider, provider_user_id, created_at, updated_at`
  - `{provider, provider_user_id} -> id, user_id, created_at, updated_at`
  - `{user_id, provider} -> id, provider_user_id, created_at, updated_at`
- **Evaluation**: All determinants are candidate keys.
- **Result**: `oauth_identities` is in **BCNF**.

#### 4. `roles`
- **Candidate key**: `id`
- **Functional dependencies**:
  - `id -> name, description, created_at, updated_at`
- **Evaluation**: The only determinant is `id`, which is the primary key.
- **Result**: `roles` is in **BCNF**.

#### 5. `permissions`
- **Candidate key**: `id`
- **Functional dependencies**:
  - `id -> description, created_at`
- **Evaluation**: The determinant `id` is the primary key.
- **Result**: `permissions` is in **BCNF**.

#### 6. `role_permissions`
- **Candidate key**: `{role_id, permission_id}`
- **Functional dependencies**:
  - `{role_id, permission_id} -> created_at`
- **Evaluation**: The determinant `{role_id, permission_id}` is the full composite key.
- **Result**: `role_permissions` is in **BCNF**.

#### 7. `organization_memberships`
- **Candidate keys**:
  1. `id`
  2. `{organization_id, user_id}` (enforced via `UNIQUE(organization_id, user_id)`)
- **Functional dependencies**:
  - `id -> organization_id, user_id, role_id, created_at, updated_at`
  - `{organization_id, user_id} -> id, role_id, created_at, updated_at`
- **Evaluation**: Both determinants are candidate keys.
- **Result**: `organization_memberships` is in **BCNF**.

#### 8. `sessions`
- **Candidate keys**:
  1. `id`
  2. `token_hash` (enforced via `UNIQUE(token_hash)`)
- **Functional dependencies**:
  - `id -> user_id, token_hash, user_agent, ip_address, expires_at, revoked_at, ...`
  - `token_hash -> id, user_id, user_agent, ip_address, expires_at, revoked_at, ...`
- **Evaluation**: Both determinants are candidate keys.
- **Result**: `sessions` is in **BCNF**.

#### 9. `organization_invites`
- **Candidate keys**:
  1. `id`
  2. `token_hash` (enforced via `UNIQUE(token_hash)`)
- **Functional dependencies**:
  - `id -> organization_id, email, role_id, invited_by_user_id, token_hash, ...`
  - `token_hash -> id, organization_id, email, role_id, invited_by_user_id, ...`
- **Evaluation**: Both determinants are candidate keys.
- **Result**: `organization_invites` is in **BCNF**.

#### 10. `api_tokens`
- **Candidate keys**:
  1. `id`
  2. `token_hash` (enforced via `UNIQUE(token_hash)`)
- **Functional dependencies**:
  - `id -> organization_id, created_by_user_id, name, token_prefix, token_hash, ...`
  - `token_hash -> id, organization_id, created_by_user_id, name, token_prefix, ...`
- **Evaluation**: Both determinants are candidate keys.
- **Result**: `api_tokens` is in **BCNF**.

---

## 7. Comparison summary: Normalization progression

The following table summarizes how anomalies are eliminated as the schema moves through normalization stages:

| Normal form | Requirement | Problem addressed | Kr0n schema state |
| :--- | :--- | :--- | :--- |
| **UNF** | None (nested / multi-valued) | High storage overhead, unbounded records | Monolithic user/org table with JSON/arrays |
| **1NF** | Atomic values, identified PK | Eliminates repeating groups and multi-valued fields | Flat table (`FLAT_MEMBERSHIP_ACCESS`) |
| **2NF** | In 1NF + no partial dependencies | Eliminates attributes depending on part of composite key | Separated `users`, `organizations`, `permissions` |
| **3NF** | In 2NF + no transitive dependencies | Eliminates non-key attributes determining other non-key attributes | Separated `roles`, `password_credentials`, `sessions` |
| **BCNF** | Every determinant is a superkey | Eliminates anomalies with overlapping candidate keys | Enforced unique constraints on `slug`, `email`, `token_hash` |

---

## 8. Practical engineering considerations and controlled denormalization

While the relational model is in BCNF, real-world high-throughput backend systems intentionally make controlled architectural decisions for performance, auditability, and distributed systems resilience:

1. **Array types for API token permissions (`api_tokens.permissions TEXT[]`)**:
   - In pure 1NF/BCNF relational theory, permissions on API tokens would use a junction table `api_token_permissions(api_token_id, permission_id)`.
   - In kr0n, API tokens store `TEXT[]` permissions directly on the row. When the high-throughput API gateway validates a token via gRPC (`ValidateAPIToken`), it retrieves the token and permissions in a single index seek without multi-table relational joins.
2. **Document payloads in outbox and audit events (`JSONB`)**:
   - `audit_events.metadata` and `outbox_events.payload` use PostgreSQL `JSONB`.
   - The aggregate event payload and audit context vary dynamically by event type (`user.registered`, `org.invite.sent`). Normalizing these polymorphic payloads into separate relational tables would introduce excessive join complexity with no relational integrity gain.
3. **Surrogate keys vs Natural keys**:
   - While natural candidate keys like `users(email)` and `organizations(slug)` exist and satisfy BCNF, the system uses UUID surrogate keys (`uuid.NewV7()` for high-write tables to preserve B-Tree write locality, and `uuid.New()` for non-clustered entities).
   - This ensures that if a user changes their email address or an organization updates its slug, foreign key references across audit logs, memberships, and sessions remain completely immutable.
