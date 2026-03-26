#!/usr/bin/env python3
import json
import os
import sys


def generate_cedar_policy(namespace: str, app_component: str, resource_uid: str,
                          action: str, groups: list[str]) -> str:
    """Genera una política Cedar."""
    groups_formatted = ',\n    '.join(f'"{g}"' for g in groups)

    return f'''permit (
  principal,
  action == {namespace}::Action::"{action}",
  resource == {namespace}::{app_component}::"{resource_uid}"
) when {{
  context.token["custom:groups"].containsAny([
    {groups_formatted}
  ])
}};
'''


def main():
    # Leer JSON desde variable de entorno
    np_context = os.environ.get('NP_CONTEXT')
    if not np_context:
        print("Error: NP_CONTEXT environment variable not set", file=sys.stderr)
        sys.exit(1)

    try:
        context = json.loads(np_context)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in NP_CONTEXT: {e}", file=sys.stderr)
        sys.exit(1)

    # Extraer configuración de Cedar
    parameters = context.get('parameters', {})
    cedar_config = parameters.get('cedar', {})
    routes = parameters.get('routes', [])

    namespace = cedar_config.get('namespace', 'DefaultNamespace')
    group_prefix = cedar_config.get('group_prefix', '')

    # Directorio de salida
    output_dir = os.environ.get('CEDAR_OUTPUT_DIR', 'cedar')
    os.makedirs(output_dir, exist_ok=True)

    policy_counter = 0

    # Iterar sobre rutas
    for route in routes:
        path = route.get('path', '')
        scope = route.get('scope', '')
        app_component = route.get('app_component', 'DefaultComponent')
        policies = route.get('policies', {})

        # Iterar sobre políticas (action -> roles)
        for action, roles in policies.items():
            policy_counter += 1

            # Generar grupos de Azure AD
            groups = [f"{group_prefix}{role}_{scope}" for role in roles]

            # Generar política Cedar
            cedar_policy = generate_cedar_policy(
                namespace=namespace,
                app_component=app_component,
                resource_uid=path,
                action=action,
                groups=groups
            )

            # Guardar archivo
            filename = f"{output_dir}/policy-{policy_counter:03d}.cedar"
            with open(filename, 'w') as f:
                f.write(cedar_policy)

            print(f"Generated: {filename}")

    print(f"\nTotal policies generated: {policy_counter}")


if __name__ == '__main__':
    main()