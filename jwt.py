#!/usr/bin/env python3
  """
  Generador de JWT para pruebas de seguridad AVP
  """

  import json
  import base64
  import hmac
  import hashlib
  import time
  from datetime import datetime

  # Configuración
  SECRET = "test-secret-key-for-smoke-testing"
  ISSUER = "https://testing.secure.istio.io"

  def base64url_encode(data: bytes | str) -> str:
      """Codifica en base64url sin padding."""
      if isinstance(data, str):
          data = data.encode('utf-8')
      return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

  def create_jwt(payload: dict, secret: str) -> str:
      """Crea un JWT firmado con HS256."""
      header = {"alg": "HS256", "typ": "JWT"}
      header_b64 = base64url_encode(json.dumps(header, separators=(',', ':')))
      payload_b64 = base64url_encode(json.dumps(payload, separators=(',', ':')))

      message = f"{header_b64}.{payload_b64}"
      signature = hmac.new(
          secret.encode('utf-8'),
          message.encode('utf-8'),
          hashlib.sha256
      ).digest()
      signature_b64 = base64url_encode(signature)

      return f"{message}.{signature_b64}"

  def generate_tokens():
      """Genera los tokens de prueba."""
      now = int(time.time())

      tokens = {
          "TOKEN_EXPIRED": {
              "description": "Token expirado - debe dar 401",
              "payload": {
                  "sub": "test-user-expired",
                  "iss": ISSUER,
                  "iat": now - 7200,
                  "exp": now - 3600  # Expiró hace 1 hora
              }
          },
          "TOKEN_VALID_NO_GROUP": {
              "description": "Token válido sin grupo smoke-testers - GET=200, POST=403",
              "payload": {
                  "sub": "test-user-no-group",
                  "iss": ISSUER,
                  "iat": now,
                  "exp": now + 86400,  # Válido por 24h
                  "groups": ["other-group"]
              }
          },
          "TOKEN_VALID_SMOKE": {
              "description": "Token válido con grupo smoke-testers - GET=200, POST=204",
              "payload": {
                  "sub": "test-user-smoke",
                  "iss": ISSUER,
                  "iat": now,
                  "exp": now + 86400,  # Válido por 24h
                  "groups": ["smoke-testers"]
              }
          },
          "TOKEN_VALID_MULTI_GROUP": {
              "description": "Token válido con múltiples grupos",
              "payload": {
                  "sub": "test-user-multi",
                  "iss": ISSUER,
                  "iat": now,
                  "exp": now + 86400,
                  "groups": ["smoke-testers", "admin", "developers"]
              }
          }
      }

      print(f"# JWT Tokens generados: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
      print(f"# Issuer: {ISSUER}")
      print(f"# Secret: {SECRET}")
      print()

      for name, config in tokens.items():
          token = create_jwt(config["payload"], SECRET)
          print(f"# {config['description']}")
          print(f'{name}="{token}"')
          print()

      # Ejemplo de uso con curl
      print("# " + "=" * 60)
      print("# EJEMPLOS DE USO")
      print("# " + "=" * 60)
      print("""
  # Cargar tokens:
  # source tokens.sh

  # Test sin token:
  # curl -s -o /dev/null -w "%{http_code}" https://hello-security.idp.poc.nullapps.io/smoke/

  # Test con token:
  # curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN_VALID_SMOKE" https://hello-security.idp.poc.nullapps.io/smoke/
  """)

  if __name__ == "__main__":
      generate_tokens()

  Guárdalo y ejecútalo:

  python3 generate_jwt.py > tokens.sh
  source tokens.sh

  O si prefieres una versión más corta para ejecutar directamente:

  python3 -c "
  import json, base64, hmac, hashlib, time

  def b64(d): return base64.urlsafe_b64encode(d if isinstance(d,bytes) else d.encode()).rstrip(b'=').decode()
  def jwt(p, s='test-secret-key-for-smoke-testing'):
      h = b64(json.dumps({'alg':'HS256','typ':'JWT'},separators=(',',':')))
      p = b64(json.dumps(p,separators=(',',':')))
      return f'{h}.{p}.{b64(hmac.new(s.encode(),(h+\".\"+p).encode(),hashlib.sha256).digest())}'

  now = int(time.time())
  print(f'TOKEN_EXPIRED=\"{jwt({\"sub\":\"expired\",\"iss\":\"https://testing.secure.istio.io\",\"iat\":now-7200,\"exp\":now-3600})}\"')
  print(f'TOKEN_VALID_NO_GROUP=\"{jwt({\"sub\":\"no-group\",\"iss\":\"https://testing.secure.istio.io\",\"iat\":now,\"exp\":now+86400,\"groups\":[\"other-group\"]})}\"')
  print(f'TOKEN_VALID_SMOKE=\"{jwt({\"sub\":\"smoke\",\"iss\":\"https://testing.secure.istio.io\",\"iat\":now,\"exp\":now+86400,\"groups\":[\"smoke-testers\"]})}\"')
  "

