#!/usr/bin/env bash
# Creates the Neon SQL-over-HTTPS REST connection + POST /sql operation.
# Needs NEON_HOST and NEON_CONNECTION_STRING in the environment (or .env). The secret header is blanked locally after create.
set -euo pipefail
S=/home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts
source $S/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
require_env NEON_HOST NEON_CONNECTION_STRING
F=Rjo4OTY0MDIw; AD=active-development
xesc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
C=$AD/connector-settings/Neon_SQL_HTTPS_Connection.xml; O=$AD/connector-action/Neon_POST_SQL.xml
umask 077
cat > "$C" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="" name="Neon PostgreSQL (SQL over HTTPS)" type="connector-settings" subType="officialboomi-X3979C-rest-prod" folderId="$F">
  <bns:encryptedValues/>
  <bns:description>Neon serverless SQL endpoint for the payment_intelligence schema (neondb). Used instead of Database V2 because the public cloud atom has no PostgreSQL JDBC driver. | built with boomi-companion v1.0.64</bns:description>
  <bns:object>
    <GenericConnectionConfig>
      <field id="url" type="string" value="https://$(xesc "$NEON_HOST")"/>
      <field id="auth" type="string" value="NONE"/>
      <field id="connectTimeout" type="integer" value="15000"/>
      <field id="readTimeout" type="integer" value="60000"/>
      <field id="cookieScope" type="string" value="GLOBAL"/>
      <field id="enableConnectionPooling" type="boolean" value="false"/>
    </GenericConnectionConfig>
  </bns:object>
</bns:Component>
XML
bash $S/boomi-component-create.sh "$C" 2>&1 | grep -E 'SUCCESS|ERROR' || true
cat > "$O" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="" name="Neon POST SQL (pi_dispatch)" type="connector-action" subType="officialboomi-X3979C-rest-prod" folderId="$F">
  <bns:encryptedValues/>
  <bns:description>POST {query, params} to /sql; always called as select pi_dispatch(\$1,\$2). The Neon-Connection-String header holds the DB credential: encrypt it in the GUI and never re-push a pulled copy. | built with boomi-companion v1.0.64</bns:description>
  <bns:object>
    <Operation returnApplicationErrors="false" trackResponse="false">
      <Archiving directory="" enabled="false"/>
      <Configuration>
        <GenericOperationConfig customOperationType="POST" operationType="EXECUTE">
          <field id="followRedirects" type="string" value="NONE"/>
          <field id="path" type="string" value="/sql"/>
          <field id="queryParameters" type="customproperties"><customProperties/></field>
          <field id="requestHeaders" type="customproperties"><customProperties>
            <properties key="Content-Type" value="application/json"/>
            <properties key="Accept" value="application/json"/>
            <properties key="Neon-Connection-String" value="$(xesc "$NEON_CONNECTION_STRING")"/>
          </customProperties></field>
          <Options/>
        </GenericOperationConfig>
      </Configuration>
      <Tracking><TrackedFields/></Tracking>
      <Caching/>
    </Operation>
  </bns:object>
</bns:Component>
XML
bash $S/boomi-component-create.sh "$O" 2>&1 | grep -E 'SUCCESS|ERROR' || true
sed -i -E 's#(key="Neon-Connection-String" value=")[^"]*(")#\1REDACTED-set-in-GUI\2#' "$O"
grep -q 'REDACTED-set-in-GUI' "$O" && echo "local secret redacted"
