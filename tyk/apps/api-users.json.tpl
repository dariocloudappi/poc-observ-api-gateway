{
  "name": "api-users",
  "slug": "api-users",
  "api_id": "api-users-001",
  "org_id": "%%TYK_ORG_ID%%",
  "use_keyless": false,
  "detailed_tracing": %%TYK_DETAILED_TRACING%%,
  "use_basic_auth": true,
  "auth": {
    "auth_header_name": "Authorization"
  },
  "version_data": {
    "not_versioned": true,
    "versions": {
      "Default": {
        "name": "Default",
        "use_extended_paths": true,
        "global_headers": {
          "Authorization": "%%UPSTREAM_USERS_AUTH_HEADER%%"
        },
        "extended_paths": {}
      }
    }
  },
  "proxy": {
    "listen_path": "/api-users/v1",
    "target_url": "%%UPSTREAM_USERS_TARGET_URL%%",
    "strip_listen_path": true
  },
  "active": true
}
