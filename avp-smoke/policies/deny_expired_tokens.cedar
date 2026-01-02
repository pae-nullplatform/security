// Policy: Placeholder forbid policy
// Token expiration is validated by the authorizer before calling AVP
// This policy is kept minimal for smoke testing
forbid (
    principal,
    action,
    resource
)
when { false };
