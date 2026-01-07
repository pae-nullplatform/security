// Policy: Allow users in smoke-testers group to perform GET and POST
permit (
    principal,
    action in [ApiAccess::Action::"GET", ApiAccess::Action::"POST"],
    resource
)
when { principal in ApiAccess::Group::"smoke-testers" };
