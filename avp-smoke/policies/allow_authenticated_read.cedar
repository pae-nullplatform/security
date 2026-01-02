// Policy: Allow any authenticated user to perform GET requests
permit (
    principal,
    action == ApiAccess::Action::"GET",
    resource
);
