// Policy: Allow users in smoke-testers group to access /smoke endpoints
permit (
    principal in ApiAccess::Group::"smoke-testers",
    action in [ApiAccess::Action::"GET", ApiAccess::Action::"POST"],
    resource
);
