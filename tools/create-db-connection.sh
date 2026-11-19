#!/usr/bin/env bash
# Creates (or, with --update, re-creates the settings of) the Boomi Database V2 connection to the tunneled PostgreSQL.
# The DB password is written to the local XML only for the API call, then blanked.
set -euo pipefail
S=/home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts
source $S/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env  # values already in the environment (e.g. Neon) survive: .env does not define them
require_env POSTGRES_PASSWORD PG_PUBLIC_HOST PG_PUBLIC_PORT
C=active-development/connector-settings/PostgreSQL_PaymentIntel_Connection.xml
ID=$(grep -o 'componentId="[0-9a-f-]\{36\}"' "$C" 2>/dev/null | cut -d'"' -f2 || true)
xesc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
umask 077
cat > "$C" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="${ID}" name="PostgreSQL - Payment Intelligence" type="connector-settings" subType="officialboomi-X3979C-dbv2da-prod" folderId="Rjo4OTY0MDIw">
  <bns:encryptedValues/>
  <bns:description>PostgreSQL for Payment Intelligence (Neon.tech, TLS required). Recreate via payment-intelligence/tools/create-db-connection.sh when the tunnel address changes. | built with boomi-companion v1.0.64</bns:description>
  <bns:object>
    <GenericConnectionConfig>
      <field id="url" type="string" value="$(xesc "jdbc:postgresql://${PG_PUBLIC_HOST}:${PG_PUBLIC_PORT}/${PG_DATABASE:-payment_intelligence}?sslmode=require&connectTimeout=15&socketTimeout=60&ApplicationName=boomi-payment-intel")"/>
      <field id="className" type="string" value="org.postgresql.Driver"/>
      <field id="username" type="string" value="$(xesc "${POSTGRES_USER:-pi_app}")"/>
      <field id="password" type="password" value="$(xesc "$POSTGRES_PASSWORD")"/>
      <field id="CustomProperties" type="customproperties"><customProperties/></field>
      <field id="schemaName" type="string" value=""/>
      <field id="connectTimeOut" type="integer" value="15"/>
      <field id="readTimeOut" type="integer" value="60"/>
      <field id="enablePooling" type="boolean" value="false"/>
    </GenericConnectionConfig>
  </bns:object>
</bns:Component>
XML
if [[ -n "$ID" ]]; then bash $S/boomi-component-push.sh "$C" --force 2>&1 | grep -E 'SUCCESS|ERROR' || true
else bash $S/boomi-component-create.sh "$C" 2>&1 | grep -E 'SUCCESS|ERROR' || true; fi
sed -i -E 's#(<field id="password" type="password" value=")[^"]*(")#\1\2#' "$C"
grep -q 'type="password" value=""' "$C" && echo "local password redacted"
grep -o 'componentId="[0-9a-f-]\{36\}"' "$C"
