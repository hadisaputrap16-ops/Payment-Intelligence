#!/usr/bin/env bash
# Creates the Twilio REST connection + send/status operations in Boomi from .env values.
# The auth token exists in the local XML only for the create call, then is blanked.
set -euo pipefail
S=/home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts
source $S/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
F=Rjo4OTY0MDIw; AD=active-development
xesc() { sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
C=$AD/connector-settings/Twilio_REST_Connection.xml
if ! grep -q 'componentId="[0-9a-f-]\{36\}"' "$C" 2>/dev/null; then
  umask 077
  cat > "$C" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="" name="Twilio REST Connection" type="connector-settings" subType="officialboomi-X3979C-rest-prod" folderId="$F">
  <bns:encryptedValues/>
  <bns:description>Twilio API (WhatsApp) - Basic auth with Account SID + Auth Token. Never re-push from a pulled copy: re-enter the token in the GUI instead. | built with boomi-companion v1.0.64</bns:description>
  <bns:object>
    <GenericConnectionConfig>
      <field id="url" type="string" value="https://api.twilio.com"/>
      <field id="auth" type="string" value="BASIC"/>
      <field id="username" type="string" value="$(xesc "$TWILIO_ACCOUNT_SID")"/>
      <field id="password" type="password" value="$(xesc "$TWILIO_AUTH_TOKEN")"/>
      <field id="preemptive" type="boolean" value="true"/>
      <field id="connectTimeout" type="integer" value="15000"/>
      <field id="readTimeout" type="integer" value="30000"/>
      <field id="cookieScope" type="string" value="GLOBAL"/>
      <field id="enableConnectionPooling" type="boolean" value="false"/>
    </GenericConnectionConfig>
  </bns:object>
</bns:Component>
XML
  bash $S/boomi-component-create.sh "$C" 2>&1 | grep -E 'SUCCESS|ERROR' || true
  sed -i -E 's#(<field id="password" type="password" value=")[^"]*(")#\1\2#' "$C"   # redact immediately
  grep -q 'type="password" value=""' "$C" && echo "local token redacted"
fi
op() { # file name desc method path
  local O=$AD/connector-action/$1.xml
  grep -q 'componentId="[0-9a-f-]\{36\}"' "$O" 2>/dev/null && return 0
  cat > "$O" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<bns:Component xmlns:bns="http://api.platform.boomi.com/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="" name="$2" type="connector-action" subType="officialboomi-X3979C-rest-prod" folderId="$F">
  <bns:encryptedValues/>
  <bns:description>$3 | built with boomi-companion v1.0.64</bns:description>
  <bns:object>
    <Operation returnApplicationErrors="true" trackResponse="false">
      <Archiving directory="" enabled="false"/>
      <Configuration>
        <GenericOperationConfig customOperationType="$4" operationType="EXECUTE">
          <field id="followRedirects" type="string" value="NONE"/>
          <field id="path" type="string" value="$5"/>
          <field id="queryParameters" type="customproperties"><customProperties/></field>
          <field id="requestHeaders" type="customproperties"><customProperties>
            $( [[ $4 == POST ]] && echo '<properties key="Content-Type" value="application/x-www-form-urlencoded"/>' )
            <properties key="Accept" value="application/json"/>
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
}
op Twilio_POST_WhatsApp_Message "Twilio POST WhatsApp Message" "POST form-encoded To/From/Body to Messages.json. returnApplicationErrors=true so Twilio error codes (e.g. 63016) reach the log" POST "/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json"
op Twilio_GET_Message_Status "Twilio GET Message Status" "GET one message by SID; path is set per document from DDP_TWILIO_PATH" GET "/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json"
