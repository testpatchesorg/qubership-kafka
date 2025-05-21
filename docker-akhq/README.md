# Overview

AKHQ is an open source GUI for Apache Kafka to manage topics, topics data, consumer groups, Kafka Connect and more.
For more information and full list of features see [official AKHQ documentation](https://github.com/tchiotludo/akhq).

# Configuration

Following documentation is a developer guide and provides some information and examples about key points that can be difficult. 
All other information see in [official AKHQ documentation](https://github.com/tchiotludo/akhq).

## Security configuration

Security groups with roles are used to specify user grants. 
Three default groups are available:
 - `admin` - with all right
 - `reader` - with only read access on all AKHQ
 - `no-roles` - without any roles, that force user to login

Custom groups also can be created.
Roles are used to provide groups rights to read/write/insert/update/delete operations with topics, topics configs, ACLs and so on. 
To filter topics available for current group `topics-filter-regexp` can be used. 
By default group has access to all topics. 

Basic authentication and LDAP can be configured:
 - For basic authentication users' login and password in sha256 are specified in YAML configuration and stored in AKHQ, 
   these users can be bound with custom or default groups configured in AKHQ.
 - For LDAP authentication users' login and password are stored on LDAP server, 
   these users can be bound with custom or default groups configured in AKHQ, also LDAP groups can be bound with AKHQ groups.

### LDAP

LDAP server configuration example for `testad.qubership.com`:

```yaml
context:
  server: 'ldap://testad.qubership.com:3268'
  managerDn: 'ADMIN_TEST'
  managerPassword: 'Qwerty123'
search:
  base: "DC=testad,DC=local"
  filter: "(&(objectClass=user)(cn={0}))"
```

**Note:** `389` is a default LDAP port, `3268` is a default LDAP Global Catalog port, `3268` is used here just as a working example.

### LDAPS

LDAPS server configuration example for `testad.qubership.com` 
(server address is specified as `dc.testad.local` because it specified this way in certificate):

```yaml
context:
  server: 'ldaps://dc.testad.local:3269'
  managerDn: 'ADMIN_TEST'
  managerPassword: 'Qwerty123'
search:
  base: "DC=testad,DC=local"
  filter: "(&(objectClass=user)(cn={0}))"
``` 

**Note:** `636` is a default LDAPS port, `3269` is a default LDAPS Global Catalog port, `3269` is used here just as a working example.

### LDAP debug

LDAP configuration can be tricky, to debug LDAP connection perform the following command:

```bash
curl -i -X POST -H "Content-Type: application/json" \
       -d '{ "configuredLevel": "TRACE" }' \
       http://localhost:8080/loggers/io.micronaut.configuration.security
```

It will increase the log level for the current session on the Micronaut part that handle LDAP authentication.

# Protobuf deserialization

To deserialize topics containing data in Protobuf format, you can set topics mapping: 
for each `topic-regex` you can specify `descriptor-file-base64` (descriptor file encoded to Base64 format using 
`base64-w 0 <name_of_desc_file>.desc > encoded` command or use online resource 
[base64encode.org](https://www.base64encode.org/)), or you can put descriptor files in `descriptors-folder` and specify 
`descriptor-file` name, also specify corresponding message types for keys and values. 
If, for example, keys are not in Protobuf format, `key-message-type` can be omitted, 
the same for `value-message-type`. 

Example configuration can look like as follows:
```yaml
akhq:
  connections:
    kafka:
      properties:
        # standard kafka properties
      deserialization:
        protobuf:
          descriptors-folder: "/app/config"
          topics-mapping:
            - topic-regex: "album.*"
              descriptor-file-base64: "Cs4BCgthbGJ1bS5wcm90bxIXY29tLm5ldGNyYWNrZXIucHJvdG9idWYidwoFQWxidW0SFAoFdGl0bGUYASABKAlSBXRpdGxlEhYKBmFydGlzdBgCIAMoCVIGYXJ0aXN0EiEKDHJlbGVhc2VfeWVhchgDIAEoBVILcmVsZWFzZVllYXISHQoKc29uZ190aXRsZRgEIAMoCVIJc29uZ1RpdGxlQiUKF2NvbS5uZXRjcmFja2VyLnByb3RvYnVmQgpBbGJ1bVByb3RvYgZwcm90bzM="
              value-message-type: "Album"
            - topic-regex: "film.*"
              descriptor-file-base64: "CuEBCgpmaWxtLnByb3RvEhRjb20uY29tcGFueS5wcm90b2J1ZiKRAQoERmlsbRISCgRuYW1lGAEgASgJUgRuYW1lEhoKCHByb2R1Y2VyGAIgASgJUghwcm9kdWNlchIhCgxyZWxlYXNlX3llYXIYAyABKAVSC3JlbGVhc2VZZWFyEhoKCGR1cmF0aW9uGAQgASgFUghkdXJhdGlvbhIaCghzdGFycmluZxgFIAMoCVIIc3RhcnJpbmdCIQoUY29tLmNvbXBhbnkucHJvdG9idWZCCUZpbG1Qcm90b2IGcHJvdG8z"
              value-message-type: "Film"
            - topic-regex: "test.*"
              descriptor-file: "streaming.desc"
              key-message-type: "Row"
              value-message-type: "Envelope"
```

To create a `.desc` file from `.proto` file perform the following command:
```bash
protoc --descriptor_set_out=<desired_name_for_desc_file>.desc --include_imports <name_of_proto_file>.proto
```

File `docker/config/streaming.desc` is a `.desc` file for Streaming Platform Protobuf message format. 
It is added to `docker-akhq` by default to the `/app/config` folder of AKHQ. 

To deserialize Streaming Platform messages produced in Protobuf format use the example above and 
just set appropriate `topic-regex` which matches topics containing data in Protobuf format 
(configs for `film` and `album` can be removed, it is just an example for multiple descriptors).