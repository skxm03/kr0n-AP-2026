-- kr0n AP · CP3 · PostgreSQL query inventory
-- Backend source: skxm03/kr0n-backend @ 237b22e7694a6f5e83929f4afca23c5409d2b2a0
-- 83 application SQL call sites (30 READ, 53 WRITE).
-- Bind the numbered parameters for each statement separately, as the Go app does.
-- This is a reference, not a batch to execute. Keep transaction boundaries from
-- the source methods. SELECT ... FOR UPDATE is a READ that locks rows.
-- Duplicate SQL is included where different application paths call it.
-- Schema/setup, test SQL, external API calls and UI-only screens are outside scope.

-- ====================================================================
-- Users and password flows
-- ====================================================================

-- WRITE W1 · Insert the new account with the supplied profile, status and timestamps.
-- Source: control-plane/internal/auth/repository/user.go:181 · CreateWithPasswordAndVerificationToken
-- Part of the CreateWithPasswordAndVerificationToken transaction (READ COMMITTED).
INSERT INTO users (id, email, display_name, avatar_url, status, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7);

-- WRITE W2 · Create the new account’s password credential.
-- Source: control-plane/internal/auth/repository/user.go:204 · CreateWithPasswordAndVerificationToken
-- Part of the CreateWithPasswordAndVerificationToken transaction (READ COMMITTED).
INSERT INTO password_credentials (user_id, password_hash, created_at, updated_at)
VALUES ($1, $2, $3, $4);

-- WRITE W3 · Insert the initial email verification token.
-- Source: control-plane/internal/auth/repository/user.go:219 · CreateWithPasswordAndVerificationToken
-- Part of the CreateWithPasswordAndVerificationToken transaction (READ COMMITTED). Only runs if the caller supplied an initial token.
INSERT INTO email_verification_tokens (id, user_id, token_hash, expires_at, created_at)
VALUES ($1, $2, $3, $4, $5);

-- READ R1 · Find an account and its password hash by canonical email.
-- Source: control-plane/internal/auth/repository/user.go:245 · GetByEmailWithPassword
SELECT u.id, u.email, u.display_name, u.avatar_url, u.status, u.email_verified_at,
       u.failed_login_attempts, u.locked_until, u.created_at, u.updated_at,
       p.password_hash
FROM users u
JOIN password_credentials p ON u.id = p.user_id
WHERE u.email = $1;

-- READ R2 · Read an account by ID without fetching password credentials.
-- Source: control-plane/internal/auth/repository/user.go:286 · GetByID
SELECT id, email, display_name, avatar_url, status, email_verified_at,
       failed_login_attempts, locked_until, created_at, updated_at
FROM users
WHERE id = $1;

-- READ R3 · Find an account and its password hash by user ID.
-- Source: control-plane/internal/auth/repository/user.go:320 · GetByIDWithPassword
SELECT u.id, u.email, u.display_name, u.avatar_url, u.status, u.email_verified_at,
       u.failed_login_attempts, u.locked_until, u.created_at, u.updated_at,
       p.password_hash
FROM users u
JOIN password_credentials p ON u.id = p.user_id
WHERE u.id = $1;

-- WRITE W4 · Record a failed login and set the lockout deadline if the threshold is reached.
-- Source: control-plane/internal/auth/repository/user.go:358 · RecordLoginFailure
UPDATE users
SET failed_login_attempts = CASE
        WHEN locked_until IS NOT NULL AND locked_until <= $2 THEN 1
        ELSE failed_login_attempts + 1
    END,
    locked_until = CASE
        WHEN (CASE WHEN locked_until IS NOT NULL AND locked_until <= $2 THEN 1 ELSE failed_login_attempts + 1 END) >= $3
        THEN $4
        ELSE locked_until
    END,
    updated_at = $2
WHERE id = $1;

-- WRITE W5 · Clear failed-login attempts and lockout deadline after successful login.
-- Source: control-plane/internal/auth/repository/user.go:382 · ResetLoginFailures
UPDATE users
SET failed_login_attempts = 0,
    locked_until = NULL,
    updated_at = $2
WHERE id = $1;

-- WRITE W6 · Mark all prior unconsumed verification tokens for the user as consumed.
-- Source: control-plane/internal/auth/repository/user.go:405 · CreateVerificationToken
-- Part of the CreateVerificationToken transaction (READ COMMITTED).
UPDATE email_verification_tokens
SET consumed_at = $2
WHERE user_id = $1 AND consumed_at IS NULL;

-- WRITE W7 · Insert the replacement email verification token.
-- Source: control-plane/internal/auth/repository/user.go:413 · CreateVerificationToken
-- Part of the CreateVerificationToken transaction (READ COMMITTED).
INSERT INTO email_verification_tokens (id, user_id, token_hash, expires_at, created_at)
VALUES ($1, $2, $3, $4, $5);

-- WRITE W8 · Mark all prior unconsumed password reset tokens for the user as consumed.
-- Source: control-plane/internal/auth/repository/user.go:435 · CreatePasswordResetToken
-- Part of the CreatePasswordResetToken transaction (READ COMMITTED).
UPDATE password_reset_tokens
SET consumed_at = $2
WHERE user_id = $1 AND consumed_at IS NULL;

-- WRITE W9 · Insert the replacement password reset token.
-- Source: control-plane/internal/auth/repository/user.go:443 · CreatePasswordResetToken
-- Part of the CreatePasswordResetToken transaction (READ COMMITTED).
INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, created_at)
VALUES ($1, $2, $3, $4, $5);

-- READ R4 · Look up the reset token by hash, joining the account and locking both rows.
-- Source: control-plane/internal/auth/repository/user.go:465 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED). The subsequent Go code checks consumption, expiry, and account status before any writes.
SELECT t.id, t.user_id, t.expires_at, t.consumed_at, u.status
FROM password_reset_tokens t
JOIN users u ON u.id = t.user_id
WHERE t.token_hash = $1
FOR UPDATE OF t, u;

-- WRITE W10 · Consume the matched reset token only if it has not been consumed.
-- Source: control-plane/internal/auth/repository/user.go:495 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED). The method requires exactly one affected row before continuing.
UPDATE password_reset_tokens
SET consumed_at = $1
WHERE id = $2 AND consumed_at IS NULL;

-- WRITE W11 · Mark any remaining unconsumed password reset tokens for the account as consumed.
-- Source: control-plane/internal/auth/repository/user.go:509 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED). Runs after the matched token has been consumed.
UPDATE password_reset_tokens
SET consumed_at = $1
WHERE user_id = $2 AND consumed_at IS NULL;

-- WRITE W12 · Insert or replace the account’s password hash, retaining the original credential creation time on conflict.
-- Source: control-plane/internal/auth/repository/user.go:517 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED).
INSERT INTO password_credentials (user_id, password_hash, created_at, updated_at)
VALUES ($1, $2, $3, $3)
ON CONFLICT (user_id) DO UPDATE
SET password_hash = EXCLUDED.password_hash,
    updated_at = EXCLUDED.updated_at;

-- WRITE W13 · Clear failed-login attempts and lockout deadline during password reset.
-- Source: control-plane/internal/auth/repository/user.go:528 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED).
UPDATE users
SET failed_login_attempts = 0,
    locked_until = NULL,
    updated_at = $1
WHERE id = $2;

-- WRITE W14 · Revoke all sessions of the account that have not already been revoked.
-- Source: control-plane/internal/auth/repository/user.go:539 · ConsumePasswordResetAndUpdatePassword
-- Part of the ConsumePasswordResetAndUpdatePassword transaction (READ COMMITTED).
UPDATE sessions
SET revoked_at = $1
WHERE user_id = $2 AND revoked_at IS NULL;

-- WRITE W15 · Change the password hash of an existing credential.
-- Source: control-plane/internal/auth/repository/user.go:562 · UpdatePassword
-- Part of the UpdatePassword transaction (READ COMMITTED). The method requires exactly one affected row before revoking sessions.
UPDATE password_credentials
SET password_hash = $1,
    updated_at = $2
WHERE user_id = $3;

-- WRITE W16 · Revoke all unrevoked sessions of the account except the supplied session.
-- Source: control-plane/internal/auth/repository/user.go:577 · UpdatePassword
-- Part of the UpdatePassword transaction (READ COMMITTED). Used when the supplied exception is non-nil and is not the zero UUID.
UPDATE sessions
SET revoked_at = $1
WHERE user_id = $2 AND id <> $3 AND revoked_at IS NULL;

-- WRITE W17 · Revoke all unrevoked sessions of the account.
-- Source: control-plane/internal/auth/repository/user.go:586 · UpdatePassword
-- Part of the UpdatePassword transaction (READ COMMITTED). Alternative branch when there is no valid session exception.
UPDATE sessions
SET revoked_at = $1
WHERE user_id = $2 AND revoked_at IS NULL;

-- READ R5 · Find an account from an existing provider identity and lock the account row.
-- Source: control-plane/internal/auth/repository/user.go:632 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). First lookup; account status is checked in Go if a row was found.
SELECT u.id, u.email, u.display_name, u.avatar_url, u.status, u.email_verified_at,
       u.failed_login_attempts, u.locked_until, u.created_at, u.updated_at
FROM oauth_identities oi
JOIN users u ON u.id = oi.user_id
WHERE oi.provider = $1 AND oi.provider_user_id = $2
FOR UPDATE OF u;

-- WRITE W18 · Record email verification for a previously unverified account resolved by provider identity.
-- Source: control-plane/internal/auth/repository/user.go:653 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only when the provider identity already resolves to an active account without a verification timestamp.
UPDATE users SET email_verified_at = $1, updated_at = $1 WHERE id = $2;

-- READ R6 · Find and lock the account with the matching verified provider email.
-- Source: control-plane/internal/auth/repository/user.go:670 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Second lookup, reached only if the provider identity is not yet linked.
SELECT id, email, display_name, avatar_url, status, email_verified_at,
       failed_login_attempts, locked_until, created_at, updated_at
FROM users
WHERE email = $1
FOR UPDATE;

-- READ R7 · Read the provider user ID already linked to this account for this provider, if present.
-- Source: control-plane/internal/auth/repository/user.go:687 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs after a matching active account is found by email; Go checks provider identity consistency.
SELECT provider_user_id FROM oauth_identities
WHERE user_id = $1 AND provider = $2;

-- WRITE W19 · Link the provider identity to the existing account.
-- Source: control-plane/internal/auth/repository/user.go:697 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only when the matching active account has no identity for that provider.
INSERT INTO oauth_identities (id, user_id, provider, provider_user_id, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $5);

-- WRITE W20 · Remove the existing password credential before completing verified-provider linkage for an unverified account.
-- Source: control-plane/internal/auth/repository/user.go:714 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only for the email-match account without a verification timestamp.
DELETE FROM password_credentials WHERE user_id = $1;

-- WRITE W21 · Revoke the linked account’s unrevoked sessions.
-- Source: control-plane/internal/auth/repository/user.go:717 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only for the email-match account without a verification timestamp.
UPDATE sessions SET revoked_at = $1 WHERE user_id = $2 AND revoked_at IS NULL;

-- WRITE W22 · Consume pending email verification tokens during verified-provider linkage.
-- Source: control-plane/internal/auth/repository/user.go:720 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only for the email-match account without a verification timestamp.
UPDATE email_verification_tokens SET consumed_at = $1 WHERE user_id = $2 AND consumed_at IS NULL;

-- WRITE W23 · Consume pending password reset tokens during verified-provider linkage.
-- Source: control-plane/internal/auth/repository/user.go:723 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only for the email-match account without a verification timestamp.
UPDATE password_reset_tokens SET consumed_at = $1 WHERE user_id = $2 AND consumed_at IS NULL;

-- WRITE W24 · Mark the linked email verified, refresh the profile and clear lockout state.
-- Source: control-plane/internal/auth/repository/user.go:731 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). Runs only for the email-match account without a verification timestamp.
UPDATE users
SET email_verified_at = $1,
    display_name = $2,
    avatar_url = COALESCE($3, avatar_url),
    failed_login_attempts = 0,
    locked_until = NULL,
    updated_at = $1
WHERE id = $4;

-- WRITE W25 · Create a new account with an already verified email for the provider profile.
-- Source: control-plane/internal/auth/repository/user.go:772 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). New-account branch; an insert uniqueness conflict can trigger one fresh attempt at the transaction.
INSERT INTO users (id, email, email_verified_at, display_name, avatar_url, status, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $7);

-- WRITE W26 · Insert the provider identity for the new account.
-- Source: control-plane/internal/auth/repository/user.go:784 · resolveOAuthUserTx
-- Part of the ResolveOAuthUser transaction (READ COMMITTED). New-account branch, after account insert; an insert uniqueness conflict can trigger one fresh attempt at the transaction.
INSERT INTO oauth_identities (id, user_id, provider, provider_user_id, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $5);

-- ====================================================================
-- Sessions and email verification
-- ====================================================================

-- WRITE W27 · Insert a session with the stored refresh-token hash, client metadata, and expiry.
-- Source: control-plane/internal/auth/repository/session.go:94 · Create
INSERT INTO sessions (id, user_id, token_hash, user_agent, ip_address, expires_at, revoked_at, created_at, last_seen_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- READ R8 · Retrieve a session by token hash and return its IP address as host text.
-- Source: control-plane/internal/auth/repository/session.go:125 · GetByTokenHash
SELECT id, user_id, token_hash, user_agent, host(ip_address), expires_at, revoked_at, created_at, last_seen_at
FROM sessions
WHERE token_hash = $1;

-- READ R9 · Find the session and user status for a refresh-token hash, locking the session row.
-- Source: control-plane/internal/auth/repository/session.go:177 · Rotate
-- First statement of the Read Committed rotation transaction; locks the session through commit or rollback.
SELECT s.id, s.user_id, s.token_hash, s.user_agent, host(s.ip_address), s.expires_at, s.revoked_at, s.created_at, s.last_seen_at,
       u.status
FROM sessions s
JOIN users u ON s.user_id = u.id
WHERE s.token_hash = $1
FOR UPDATE OF s;

-- READ R10 · Look for an old token hash in refresh-token history when the current session lookup has no row.
-- Source: control-plane/internal/auth/repository/session.go:207 · Rotate
-- Fallback branch of the same rotation transaction, executed only after the active-session lookup finds no row.
SELECT session_id
FROM refresh_token_history
WHERE token_hash = $1;

-- WRITE W28 · Revoke the session linked to a previously rotated hash while preserving an existing revocation timestamp.
-- Source: control-plane/internal/auth/repository/session.go:213 · Rotate
-- Executed if the history lookup finds a row; this branch attempts to commit the revocation and returns ErrSessionRevoked.
UPDATE sessions
SET revoked_at = COALESCE(revoked_at, $1)
WHERE id = $2;

-- WRITE W29 · Record the outgoing token hash in rotation history, ignoring a duplicate history hash.
-- Source: control-plane/internal/auth/repository/session.go:236 · Rotate
-- After the caller validates the locked session and supplies replacements; committed with the following session update.
INSERT INTO refresh_token_history (token_hash, session_id, user_id, rotated_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (token_hash) DO NOTHING;

-- WRITE W30 · Replace the token hash and update last-seen and expiry timestamps for the locked session.
-- Source: control-plane/internal/auth/repository/session.go:245 · Rotate
-- Normal rotation branch; commits the update and history insert together.
UPDATE sessions
SET token_hash = $1, last_seen_at = $2, expires_at = $3
WHERE id = $4;

-- WRITE W31 · Set the revocation timestamp for a token hash if it was not already set.
-- Source: control-plane/internal/auth/repository/session.go:270 · RevokeByTokenHash
UPDATE sessions
SET revoked_at = COALESCE(revoked_at, $1)
WHERE token_hash = $2;

-- READ R11 · List one user’s unrevoked sessions whose expiry is after the supplied time, newest last-seen first.
-- Source: control-plane/internal/auth/repository/session.go:286 · ListActiveByUserID
SELECT id, user_id, token_hash, user_agent, host(ip_address), expires_at, revoked_at, created_at, last_seen_at
FROM sessions
WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > $2
ORDER BY last_seen_at DESC;

-- WRITE W32 · Revoke the specified session only when it belongs to the given user; preserve any prior revocation.
-- Source: control-plane/internal/auth/repository/session.go:331 · RevokeByID
UPDATE sessions
SET revoked_at = COALESCE(revoked_at, $1)
WHERE id = $2 AND user_id = $3;

-- READ R12 · Look up the verification token and its associated user status by hash, locking the token row.
-- Source: control-plane/internal/auth/repository/verification.go:94 · VerifyAndConsume
-- First statement in the Read Committed verification transaction. The application checks that the token is unused and unexpired and that the user is active.
SELECT t.id, t.user_id, t.token_hash, t.expires_at, t.consumed_at, t.created_at,
       u.id, u.status
FROM email_verification_tokens t
LEFT JOIN users u ON t.user_id = u.id
WHERE t.token_hash = $1
FOR UPDATE OF t;

-- WRITE W33 · Mark the user’s email as verified, keeping the original verification time when present; update the user timestamp.
-- Source: control-plane/internal/auth/repository/verification.go:142 · VerifyAndConsume
-- Runs only after validation, and commits with token consumption.
UPDATE users
SET email_verified_at = COALESCE(email_verified_at, $1), updated_at = $1
WHERE id = $2;

-- WRITE W34 · Mark all still-unused verification tokens matching the token ID or owning user as consumed.
-- Source: control-plane/internal/auth/repository/verification.go:152 · VerifyAndConsume
-- Final statement in the same transaction; a rollback leaves both the user and token rows unchanged.
UPDATE email_verification_tokens
SET consumed_at = $1
WHERE (id = $2 OR user_id = $3) AND consumed_at IS NULL;

-- ====================================================================
-- Organizations and GitHub installations
-- ====================================================================

-- READ R13 · Look up the caller’s role in the organization.
-- Source: control-plane/internal/auth/repository/org.go:192 · RolePermissions
SELECT role_id
FROM organization_memberships
WHERE organization_id = $1 AND user_id = $2;

-- READ R14 · List permission IDs for the role, ordered by permission ID.
-- Source: control-plane/internal/auth/repository/org.go:204 · RolePermissions
SELECT permission_id
FROM role_permissions
WHERE role_id = $1
ORDER BY permission_id;

-- READ R15 · List roles and sorted permission arrays, including roles with no permissions.
-- Source: control-plane/internal/auth/repository/org.go:228 · ListRoles
SELECT r.id, r.name, r.description,
       COALESCE(array_agg(rp.permission_id ORDER BY rp.permission_id) FILTER (WHERE rp.permission_id IS NOT NULL), '{}')
FROM roles r
LEFT JOIN role_permissions rp ON rp.role_id = r.id
GROUP BY r.id, r.name, r.description
ORDER BY r.id;

-- WRITE W35 · Insert the new organization with caller-supplied ID and timestamps.
-- Source: control-plane/internal/auth/repository/org.go:260 · CreateOrg
-- Read Committed transaction: insert organization then owner membership; commit both together.
INSERT INTO organizations (id, name, slug, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5);

-- WRITE W36 · Grant the creator the owner membership for the new organization.
-- Source: control-plane/internal/auth/repository/org.go:272 · CreateOrg
-- Read Committed transaction: insert organization then owner membership; commit both together.
INSERT INTO organization_memberships (id, organization_id, user_id, role_id, created_at, updated_at)
VALUES ($1, $2, $3, 'owner', $4, $4);

-- READ R16 · List a user’s organizations with their roles, newest organizations first.
-- Source: control-plane/internal/auth/repository/org.go:285 · ListUserOrgs
SELECT o.id, o.name, o.slug, om.role_id, o.created_at, o.updated_at
FROM organizations o
JOIN organization_memberships om ON om.organization_id = o.id
WHERE om.user_id = $1
ORDER BY o.created_at DESC;

-- READ R17 · Look up an organization by ID.
-- Source: control-plane/internal/auth/repository/org.go:311 · GetOrg
SELECT id, name, slug, created_at, updated_at
FROM organizations
WHERE id = $1;

-- WRITE W37 · Rename an organization, update its timestamp, and return its current row.
-- Source: control-plane/internal/auth/repository/org.go:328 · UpdateOrg
UPDATE organizations
SET name = $1, updated_at = $2
WHERE id = $3
RETURNING id, name, slug, created_at, updated_at;

-- WRITE W38 · Delete the organization by ID.
-- Source: control-plane/internal/auth/repository/org.go:344 · DeleteOrg
DELETE FROM organizations WHERE id = $1;

-- READ R18 · List an organization’s members with account details, oldest membership first.
-- Source: control-plane/internal/auth/repository/org.go:357 · ListMembers
SELECT u.id, u.email, u.display_name, om.role_id, om.created_at
FROM organization_memberships om
JOIN users u ON u.id = om.user_id
WHERE om.organization_id = $1
ORDER BY om.created_at ASC;

-- READ R19 · Resolve an existing user’s account by email before adding a membership.
-- Source: control-plane/internal/auth/repository/org.go:383 · AddMemberByEmail
SELECT id, email, display_name
FROM users
WHERE email = $1;

-- WRITE W39 · Insert a member with the requested role and timestamps.
-- Source: control-plane/internal/auth/repository/org.go:395 · AddMemberByEmail
INSERT INTO organization_memberships (id, organization_id, user_id, role_id, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $5);

-- READ R20 · Read and lock the target membership before a potential role change.
-- Source: control-plane/internal/auth/repository/org.go:420 · UpdateMemberRole
-- Read Committed transaction: lock target membership, conditionally check and lock owners, then update.
SELECT role_id
FROM organization_memberships
WHERE organization_id = $1 AND user_id = $2
FOR UPDATE;

-- WRITE W40 · Set a member’s role and update its timestamp.
-- Source: control-plane/internal/auth/repository/org.go:439 · UpdateMemberRole
-- Read Committed transaction: lock target membership, conditionally check and lock owners, then update.
UPDATE organization_memberships
SET role_id = $1, updated_at = $2
WHERE organization_id = $3 AND user_id = $4;

-- READ R21 · Read and lock the target membership before removal.
-- Source: control-plane/internal/auth/repository/org.go:460 · RemoveMember
-- Read Committed transaction: lock target membership, conditionally check and lock owners, then remove membership and revoke the creator’s organization tokens atomically.
SELECT role_id
FROM organization_memberships
WHERE organization_id = $1 AND user_id = $2
FOR UPDATE;

-- WRITE W41 · Delete the organization membership for the target user.
-- Source: control-plane/internal/auth/repository/org.go:479 · RemoveMember
-- Read Committed transaction: lock target membership, conditionally check and lock owners, then remove membership and revoke the creator’s organization tokens atomically.
DELETE FROM organization_memberships
WHERE organization_id = $1 AND user_id = $2;

-- WRITE W42 · Revoke tokens created by the removed member in this organization, preserving earlier revocations.
-- Source: control-plane/internal/auth/repository/org.go:488 · RemoveMember
-- Read Committed transaction: lock target membership, conditionally check and lock owners, then remove membership and revoke the creator’s organization tokens atomically.
UPDATE api_tokens
SET revoked_at = COALESCE(revoked_at, now())
WHERE organization_id = $1 AND created_by_user_id = $2;

-- READ R22 · Lock all owner memberships for the Go last-owner check.
-- Source: control-plane/internal/auth/repository/org.go:500 · ensureMultipleOwners
-- Runs in the caller’s transaction only for an owner removal or demotion. The Go loop counts locked owner rows and rejects the change when at most one remains.
SELECT user_id
FROM organization_memberships
WHERE organization_id = $1 AND role_id = 'owner'
FOR UPDATE;

-- READ R23 · Check whether the invitee’s email already belongs to an organization member.
-- Source: control-plane/internal/auth/repository/org.go:534 · CreateInvite
-- Read Committed transaction: check the invitee membership, revoke prior pending invitations, then insert the new invitation.
SELECT EXISTS (
	SELECT 1 FROM organization_memberships om
	JOIN users u ON u.id = om.user_id
	WHERE om.organization_id = $1 AND u.email = $2
);

-- WRITE W43 · Revoke earlier unaccepted and unrevoked invitations for the same organization and email.
-- Source: control-plane/internal/auth/repository/org.go:547 · CreateInvite
-- Read Committed transaction: check the invitee membership, revoke prior pending invitations, then insert the new invitation.
UPDATE organization_invites SET revoked_at = $3
WHERE organization_id = $1 AND email = $2 AND accepted_at IS NULL AND revoked_at IS NULL;

-- WRITE W44 · Insert the new invitation with its role, inviter, token digest, and expiry.
-- Source: control-plane/internal/auth/repository/org.go:554 · CreateInvite
-- Read Committed transaction: check the invitee membership, revoke prior pending invitations, then insert the new invitation.
INSERT INTO organization_invites (id, organization_id, email, role_id, invited_by_user_id, token_hash, expires_at, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8);

-- READ R24 · Read and lock the invitation identified by its token digest.
-- Source: control-plane/internal/auth/repository/org.go:580 · AcceptInvite
-- Read Committed transaction: lock invitation, validate its status and matching user email, mark it accepted, insert membership if absent, then read the organization and commit.
SELECT id, organization_id, email, role_id, expires_at, accepted_at, revoked_at
FROM organization_invites
WHERE token_hash = $1
FOR UPDATE;

-- READ R25 · Read the accepting user’s email for comparison to that of the invitee.
-- Source: control-plane/internal/auth/repository/org.go:596 · AcceptInvite
-- Read Committed transaction: lock invitation, validate its status and matching user email, mark it accepted, insert membership if absent, then read the organization and commit.
SELECT email FROM users WHERE id = $1;

-- WRITE W45 · Write the acceptance timestamp to the locked invitation.
-- Source: control-plane/internal/auth/repository/org.go:604 · AcceptInvite
-- Read Committed transaction: lock invitation, validate its status and matching user email, mark it accepted, insert membership if absent, then read the organization and commit.
UPDATE organization_invites
SET accepted_at = $1
WHERE id = $2;

-- WRITE W46 · Insert the invited membership if absent; retain any existing membership role.
-- Source: control-plane/internal/auth/repository/org.go:613 · AcceptInvite
-- Read Committed transaction: lock invitation, validate its status and matching user email, mark it accepted, insert membership if absent, then read the organization and commit.
INSERT INTO organization_memberships (id, organization_id, user_id, role_id, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $5)
ON CONFLICT (organization_id, user_id) DO NOTHING;

-- READ R26 · Return the organization and the accepting user’s effective membership role.
-- Source: control-plane/internal/auth/repository/org.go:622 · AcceptInvite
-- Read Committed transaction: lock invitation, validate its status and matching user email, mark it accepted, insert membership if absent, then read the organization and commit.
SELECT o.id, o.name, o.slug, om.role_id, o.created_at, o.updated_at
FROM organizations o
JOIN organization_memberships om ON om.organization_id = o.id AND om.user_id = $2
WHERE o.id = $1;

-- WRITE W47 · Mark an unaccepted invitation revoked within the organization, preserving an earlier revocation.
-- Source: control-plane/internal/auth/repository/org.go:639 · RevokeInvite
UPDATE organization_invites
SET revoked_at = COALESCE(revoked_at, $1)
WHERE id = $2 AND organization_id = $3 AND accepted_at IS NULL;

-- WRITE W48 · Insert an organization API token record with its digest and granted permissions.
-- Source: control-plane/internal/auth/repository/org.go:655 · CreateAPIToken
INSERT INTO api_tokens (id, organization_id, created_by_user_id, name, token_prefix, token_hash, permissions, expires_at, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- READ R27 · List non-revoked organization API tokens newest first, omitting their digests.
-- Source: control-plane/internal/auth/repository/org.go:667 · ListAPITokens
SELECT id, organization_id, created_by_user_id, name, token_prefix, permissions, expires_at, last_used_at, revoked_at, created_at
FROM api_tokens
WHERE organization_id = $1 AND revoked_at IS NULL
ORDER BY created_at DESC;

-- WRITE W49 · Revoke the organization’s API token, preserving any earlier revocation.
-- Source: control-plane/internal/auth/repository/org.go:691 · RevokeAPIToken
UPDATE api_tokens
SET revoked_at = COALESCE(revoked_at, $1)
WHERE id = $2 AND organization_id = $3;

-- READ R28 · Fetch the token by digest with its creator account status.
-- Source: control-plane/internal/auth/repository/org.go:711 · GetAPITokenByHash
SELECT t.id, t.organization_id, t.created_by_user_id, t.name, t.token_prefix, t.token_hash,
       t.permissions, t.expires_at, t.last_used_at, t.revoked_at, t.created_at,
       u.status
FROM api_tokens t
JOIN users u ON u.id = t.created_by_user_id
WHERE t.token_hash = $1;

-- WRITE W50 · Update the last-used timestamp only when unset or older than the configured interval.
-- Source: control-plane/internal/auth/repository/org.go:734 · TouchAPITokenLastUsed
-- Parameter types: timestamptz, uuid, double precision (seconds).
UPDATE api_tokens SET last_used_at = $1
WHERE id = $2 AND (last_used_at IS NULL OR last_used_at < $1 - make_interval(secs => $3));

-- WRITE W51 · Register or refresh an installation belonging to the same organization.
-- Source: control-plane/internal/auth/repository/org.go:745 · UpsertGitHubInstallation
INSERT INTO github_installations (
	id, organization_id, installation_id, account_login, account_type,
	repository_selection, status, created_by_user_id, created_at, updated_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (installation_id) DO UPDATE
SET account_login = EXCLUDED.account_login,
    account_type = EXCLUDED.account_type,
    repository_selection = EXCLUDED.repository_selection,
    status = EXCLUDED.status,
    updated_at = EXCLUDED.updated_at
WHERE github_installations.organization_id = EXCLUDED.organization_id
RETURNING id, organization_id, installation_id, account_login, account_type,
          repository_selection, status, created_by_user_id, created_at, updated_at;

-- READ R29 · List installations linked to the organization, newest first.
-- Source: control-plane/internal/auth/repository/org.go:778 · ListGitHubInstallations
SELECT id, organization_id, installation_id, account_login, account_type,
       repository_selection, status, created_by_user_id, created_at, updated_at
FROM github_installations
WHERE organization_id = $1
ORDER BY created_at DESC;

-- WRITE W52 · Remove the matching installation from that organization.
-- Source: control-plane/internal/auth/repository/org.go:810 · DeleteGitHubInstallation
DELETE FROM github_installations
WHERE organization_id = $1 AND installation_id = $2;

-- ====================================================================
-- Audit events
-- ====================================================================

-- WRITE W53 · Append an audit record with actor, resource, client, and JSON metadata fields.
-- Source: control-plane/internal/auth/repository/audit.go:68 · Insert
INSERT INTO audit_events (
	id, organization_id, actor_user_id, actor_type, action,
	resource_type, resource_id, ip_address, user_agent, metadata, created_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11);

-- READ R30 · List organization audit events newest first with limit/offset pagination.
-- Source: control-plane/internal/auth/repository/audit.go:83 · ListByOrg
SELECT id, organization_id, actor_user_id, actor_type, action,
       resource_type, COALESCE(resource_id, ''), host(ip_address), user_agent, metadata, created_at
FROM audit_events
WHERE organization_id = $1
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;
