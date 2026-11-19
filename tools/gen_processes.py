#!/usr/bin/env python3
"""Generates the Payment Intelligence Boomi process XML from one place.

Usage (via tools/gen-processes.sh, which supplies WA_TO / WA_FROM from .env):
    gen_processes.py ids.json out_dir
ids.json holds component IDs; any process whose dependencies are still missing is skipped.
"""
import json, os, sys
from xml.sax.saxutils import escape, quoteattr

IDS = json.load(open(sys.argv[1]))
OUT = sys.argv[2]
FOLDER = IDS["folder"]
TAG = " | built with boomi-companion v1.0.64"
LISTENER = 'allowSimultaneous="true" enableUserLog="false" processLogOnErrorOnly="false" purgeDataImmediately="false" stopProcessingIfZeroDocuments="true" updateRunDates="false" workload="general"'
SUB = LISTENER.replace('allowSimultaneous="true"', 'allowSimultaneous="false"')

# ───────────── shape builders ─────────────
def dp(name, to, x, y, ident=None, text=None):
    a = f' identifier="{ident}"' if ident else ""
    t = f' text="{text}"' if text else ""
    return f'<dragpoint{a} name="{name}"{t} toShape="{to}" x="{x}" y="{y}"/>'

class P:
    def __init__(self):
        self.shapes, self.n = [], 0
    def add(self, image, stype, label, x, y, config, drags):
        self.n += 1
        name = f"shape{self.n}"
        self.shapes.append((name, image, stype, label, x, y, config, drags))
        return name
    def xml(self):
        out = []
        for name, image, stype, label, x, y, config, drags in self.shapes:
            d = "".join(f(name) for f in drags) if drags else ""
            out.append(f'<shape image="{image}" name="{name}" shapetype="{stype}" userlabel={quoteattr(label)} x="{x}.0" y="{y}.0">'
                       f'<configuration>{config}</configuration><dragpoints>{d}</dragpoints></shape>')
        return "\n".join(out)

def to(target, x, y):            # single outgoing path
    return lambda n: dp(f"{n}.dragpoint1", target, x - 16, y + 8)

def groovy(script):
    return ('<dataprocess><step index="1" key="1" name="Custom Scripting" processtype="12">'
            '<dataprocessscript language="groovy2" useCache="true"><script><![CDATA[' + script + ']]></script>'
            '</dataprocessscript></step></dataprocess>')

def message(txt, params="", combined=False):
    return f'<message combined="{str(combined).lower()}"><msgTxt>{escape(txt)}</msgTxt><msgParameters>{params}</msgParameters></message>'

RESULT_PARAM = ('<parametervalue key="0" usesEncryption="false" valueType="profile"><profileelement elementId="3" '
                'elementName="result (Root/Object/result)" profileId="{p}" profileType="profile.json"/></parametervalue>')

def db_step():  # Neon SQL over HTTPS (REST): the cloud atom has no PostgreSQL JDBC driver
    return (f'<connectoraction actionType="POST" allowDynamicCredentials="NONE" connectionId="{IDS["db_conn"]}" '
            f'connectorType="officialboomi-X3979C-rest-prod" hideSettings="false" operationId="{IDS["db_op"]}">'
            '<parameters/><dynamicProperties/></connectoraction>')

def decision_dpp(label, prop, value):
    return (f'<decision comparison="equals" name={quoteattr(label)}><decisionvalue valueType="process">'
            f'<processparameter processproperty="{prop}" processpropertydefaultvalue=""/></decisionvalue>'
            f'<decisionvalue valueType="static"><staticparameter staticproperty="{value}"/></decisionvalue></decision>')

def notify_catch(title):
    return (f'<notify disableEvent="true" enableUserLog="false" perExecution="false" title="{title}">'
            f'<notifyMessage>{escape(title)}: {{1}}</notifyMessage><notifyMessageLevel>ERROR</notifyMessageLevel>'
            '<notifyParameters><parametervalue key="0" usesEncryption="false" valueType="track"><trackparameter defaultValue="" '
            'propertyId="meta.base.catcherrorsmessage" propertyName="Base - Try/Catch Message"/></parametervalue></notifyParameters></notify>')

def notify_current(title):
    return (f'<notify disableEvent="true" enableUserLog="false" perExecution="false" title="{title}">'
            f'<notifyMessage>{escape(title)}: {{1}}</notifyMessage><notifyMessageLevel>INFO</notifyMessageLevel>'
            '<notifyParameters><parametervalue key="0" usesEncryption="false" valueType="current"/></notifyParameters></notify>')

def processcall(pid, child_return):
    return (f'<processcall abort="true" processId="{pid}" wait="true"><parameters/><returnpaths>'
            f'<returnpaths childShapeName="{child_return}"/></returnpaths></processcall>')

def trycatch(retry):
    return f'<catcherrors catchAll="true" retryCount="{retry}"/>'

def component(name, desc, process_attrs, p):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<bns:Component xmlns:bns="http://api.platform.boomi.com/" '
            f'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" componentId="" name={quoteattr(name)} type="process" folderId="{FOLDER}">\n'
            f'  <bns:encryptedValues/>\n  <bns:description>{escape(desc + TAG)}</bns:description>\n  <bns:object>\n'
            f'    <process {process_attrs}>\n      <shapes>\n{p.xml()}\n      </shapes>\n    </process>\n  </bns:object>\n'
            f'  <bns:processOverrides/>\n</bns:Component>\n')

# ───────────── Groovy (each kept short; JSON-in-JSON escaping is not possible natively) ─────────────
HDR = """import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import com.boomi.execution.ExecutionUtil
def sqlReq = { String fn, String payload -> JsonOutput.toJson([query: 'select pi_dispatch($1,$2) as result', params: [fn, payload]]) }
"""
# Neon /sql answers {"rows":[{"result":"<json text>"}], ...}; pi_dispatch always returns exactly one row.
DBROW = """def dbResult = { String raw ->
    def resp = new JsonSlurper().parseText(raw)
    def r = resp.rows ? resp.rows[0].result : null
    r instanceof String ? new JsonSlurper().parseText(r) : r
}
"""

LOOP_OPEN = """for (int i = 0; i < dataContext.getDataCount(); i++) {
    InputStream is = dataContext.getStream(i)
    Properties props = dataContext.getProperties(i)
    String raw = is.getText("UTF-8")
"""
LOOP_CLOSE = """    dataContext.storeStream(new ByteArrayInputStream(out.getBytes("UTF-8")), props)
}
"""

G_UNWRAP_PLAIN = HDR + DBROW + "/* Emit the engine's JSON as the document. */\n" + LOOP_OPEN + \
    """    String out = JsonOutput.toJson(dbResult(raw))
""" + LOOP_CLOSE

G_WRAP_INGEST = HDR + "/* Wrap the raw HTTP body as pi_dispatch('ingest', <body>); PostgreSQL does the validation. */\n" + LOOP_OPEN + \
    """    String out = sqlReq("ingest", raw ?: "")
""" + LOOP_CLOSE

G_UNWRAP_INGEST = HDR + DBROW + "/* valid -> emit agent_input for the agent; invalid -> emit the rejection as the API response. */\n" + LOOP_OPEN + \
    """    def res = dbResult(raw)
    boolean valid = res instanceof Map && res.valid == true
    ExecutionUtil.setDynamicProcessProperty("DPP_VALID", String.valueOf(valid), false)
    ExecutionUtil.setDynamicProcessProperty("DPP_TRANSACTION_ID", valid ? res.transaction_id.toString() : "", false)
    String out = JsonOutput.toJson(valid ? res.agent_input : res)
""" + LOOP_CLOSE

G_BUILD_DECIDE = HDR + """/* Turn the structured agent envelope {success, data} into pi_dispatch('decide'); any failure becomes agent_error. */
def tryParse = { s -> try { new JsonSlurper().parseText(s.toString()) } catch (Exception e) { null } }
String tx = ExecutionUtil.getDynamicProcessProperty("DPP_TRANSACTION_ID")
""" + LOOP_OPEN + """    def env = tryParse(raw), ai = null
    String err = null
    if (env instanceof Map && env.success == true) {
        ai = env.data instanceof String ? tryParse(env.data) : env.data
        if (ai instanceof Map && ai.classification == null && ai.response != null) ai = ai.response instanceof Map ? ai.response : tryParse(ai.response)
        if (!(ai instanceof Map)) { err = "agent returned no structured verdict"; ai = null }
    } else {
        err = env instanceof Map ? (env.error ?: "agent returned success=false").toString() : "agent output was not JSON"
    }
    String out = sqlReq("decide", JsonOutput.toJson([transaction_id: tx, ai: ai, agent_error: err]))
""" + LOOP_CLOSE

G_UNWRAP_DECIDE = HDR + DBROW + "/* Emit the final decision; DPP_NOTIFY drives the WhatsApp branch. */\n" + LOOP_OPEN + \
    """    def res = dbResult(raw)
    ExecutionUtil.setDynamicProcessProperty("DPP_NOTIFY", String.valueOf(res instanceof Map && res.notify == true), false)
    String out = JsonOutput.toJson(res)
""" + LOOP_CLOSE

def g_build_whatsapp(to_num, from_num, content_sid):
    return HDR + f"""/* Build the Twilio form body: free-form Body with the Boomi alert text (needs an open 24h WhatsApp session).
   To/From come from .env at build time; never a secret. {"" if not content_sid else "Built in template mode: sends ContentSid instead of Body."} */
String TO = {json.dumps(to_num)}, FROM = {json.dumps(from_num)}
def enc = {{ s -> URLEncoder.encode(s ?: "", "UTF-8") }}
""" + LOOP_OPEN + """    def d = new JsonSlurper().parseText(raw)
    String body = d.whatsapp_body ?: ("Payment Intelligence alert for " + d.transaction_id)
    ExecutionUtil.setDynamicProcessProperty("DPP_WA_TO", TO, false)
    ExecutionUtil.setDynamicProcessProperty("DPP_WA_BODY", body, false)
    String out = "To=" + enc(TO) + "&From=" + enc(FROM) + """ + (
        f'"&ContentSid=" + enc({json.dumps(content_sid)})' if content_sid else '"&Body=" + enc(body)') + """
""" + LOOP_CLOSE

G_BUILD_LOG = HDR + """/* Normalise Twilio success {sid,status}, Twilio error {code,message,status} or our transport-fault envelope. */
""" + LOOP_OPEN + """    def r = null
    try { r = new JsonSlurper().parseText(raw) } catch (Exception e) { }
    boolean ok = r instanceof Map && r.sid
    def payload = [
        transaction_id: ExecutionUtil.getDynamicProcessProperty("DPP_TRANSACTION_ID"),
        to            : ExecutionUtil.getDynamicProcessProperty("DPP_WA_TO"),
        message_body  : ExecutionUtil.getDynamicProcessProperty("DPP_WA_BODY"),
        message_sid   : ok ? r.sid : null,
        delivery_status: ok ? r.status : "SEND_FAILED",
        http_status   : ok ? 201 : (r instanceof Map && r.status instanceof Number ? r.status : null),
        error_code    : r instanceof Map ? (ok ? r.error_code : r.code)?.toString() : null,
        error_message : r instanceof Map ? (ok ? r.error_message : r.message)?.toString() : "unparseable Twilio response",
        attempt_count : r instanceof Map && r.attempts ? r.attempts : 1]
    String out = sqlReq("log_notification", JsonOutput.toJson(payload))
""" + LOOP_CLOSE

def g_build_email(to_addr):
    return HDR + f"""/* Build the email alert for the shared 'Send Notifications' process: it reads DPPs MESSAGE (body) and EMAIL_TO.
   Subject and attachment name are set here as outbound mail properties; the document itself becomes the .txt attachment.
   The recipient comes from the 'Send Mail Notification' operation default at build time. */
String TO = {json.dumps(to_addr)}
def mask = {{ String a -> a ? a.replaceAll(/^(.).*?@/, '$1***@') : '' }}
""" + LOOP_OPEN + """    def d = new JsonSlurper().parseText(raw)
    String body = d.whatsapp_body ?: ("Payment Intelligence alert for " + d.transaction_id)
    body += "\\n\\nExplanation: " + (d.explanation ?: "-") + "\\n\\nThis alert was generated by the Boomi Payment Intelligence workflow."
    ExecutionUtil.setDynamicProcessProperty("MESSAGE", body, false)
    ExecutionUtil.setDynamicProcessProperty("EMAIL_TO", TO, false)
    ExecutionUtil.setDynamicProcessProperty("DPP_ALERT_TO", mask(TO), false)
    ExecutionUtil.setDynamicProcessProperty("DPP_ALERT_BODY", body, false)
    ExecutionUtil.setDynamicProcessProperty("DPP_MAIL_STATUS", "SENT", false)
    ExecutionUtil.setDynamicProcessProperty("DPP_MAIL_ERROR", "", false)
    props.setProperty("connector.dynamic.mail.subject", "[Payment Intelligence] " + d.classification + " - " + d.transaction_id + " (risk " + d.risk_score + "/100)")
    props.setProperty("connector.dynamic.mail.filename", (d.investigation_ref ?: d.transaction_id) + ".txt")
    String out = body
""" + LOOP_CLOSE

G_EMAIL_FAIL = HDR + """/* Mail send failed after retry: record it for the notification log (details are in the process log). */
""" + LOOP_OPEN + """    String m = props.getProperty("meta.base.catcherrorsmessage")
    ExecutionUtil.setDynamicProcessProperty("DPP_MAIL_STATUS", "SEND_FAILED", false)
    ExecutionUtil.setDynamicProcessProperty("DPP_MAIL_ERROR", m ?: "Mail send failed after retry (see process log)", false)
    String out = raw
""" + LOOP_CLOSE

G_EMAIL_RESULT = HDR + """/* Branch 2 runs after the send branch finished: report its outcome from the DPPs. */
""" + LOOP_OPEN + """    String err = ExecutionUtil.getDynamicProcessProperty("DPP_MAIL_ERROR")
    String out = JsonOutput.toJson([channel: "EMAIL", status: ExecutionUtil.getDynamicProcessProperty("DPP_MAIL_STATUS") ?: "SEND_FAILED",
                                    error_message: err ?: null])
""" + LOOP_CLOSE

G_BUILD_LOG_EMAIL = HDR + """/* Email result {channel, status, error_message} -> pi_dispatch('log_notification'). */
""" + LOOP_OPEN + """    def r = null
    try { r = new JsonSlurper().parseText(raw) } catch (Exception e) { }
    boolean ok = r instanceof Map && r.status == "SENT"
    def payload = [
        transaction_id : ExecutionUtil.getDynamicProcessProperty("DPP_TRANSACTION_ID"),
        channel        : "EMAIL",
        to             : ExecutionUtil.getDynamicProcessProperty("DPP_ALERT_TO"),
        message_body   : ExecutionUtil.getDynamicProcessProperty("DPP_ALERT_BODY"),
        message_sid    : null,
        delivery_status: ok ? "SENT" : "SEND_FAILED",
        http_status    : null,
        error_code     : ok ? null : "MAIL_SEND_FAILED",
        error_message  : ok ? null : (r instanceof Map ? r.error_message : "unparseable mail result"),
        attempt_count  : 1]
    String out = sqlReq("log_notification", JsonOutput.toJson(payload))
""" + LOOP_CLOSE

G_CHAT_PROMPT = HDR + """/* Portal chat request {message, history:[{role:user|assistant, content}]} -> plain-text prompt for the conversational agent.
   Only the last 6 turns are replayed (the Agent step is single-turn); lengths are capped. */
""" + LOOP_OPEN + """    def d = null
    try { d = new JsonSlurper().parseText(raw) } catch (Exception e) { }
    String msg = (d instanceof Map && d.message) ? d.message.toString().trim() : ""
    if (msg.length() > 2000) msg = msg.substring(0, 2000)
    def hist = (d instanceof Map && d.history instanceof List) ? d.history.takeRight(6) : []
    StringBuilder sb = new StringBuilder()
    if (hist) {
        sb.append("Previous conversation (for context only):\\n")
        hist.each { h -> String c = (h?.content ?: "").toString(); if (c.length() > 1500) c = c.substring(0, 1500)
            sb.append(h?.role == "assistant" ? "Assistant: " : "Analyst: ").append(c).append("\\n") }
        sb.append("\\nAnalyst's new message: ")
    }
    sb.append(msg ?: "Hello")
    String out = sb.toString()
""" + LOOP_CLOSE

G_CHAT_EXTRACT = HDR + """/* Conversational agent output is an SSE stream: take the 'event: message' content. A JSON {success:false} is an agent-side rejection. */
""" + LOOP_OPEN + """    String reply = null, sid = null, err = null
    def m = raw =~ /(?m)^event: message\\s*\\ndata: (.+)$/
    if (m.find()) { def j = new JsonSlurper().parseText(m.group(1)); reply = j.content; sid = j.session_id }
    else { try { def j = new JsonSlurper().parseText(raw); err = (j instanceof Map) ? (j.error ?: j.message ?: "agent returned no message") : "agent returned no message" } catch (Exception e) { err = "agent returned no message" } }
    String out = JsonOutput.toJson(reply != null ? [ok: true, reply: reply, session_id: sid] : [ok: false, error: err.toString()])
""" + LOOP_CLOSE

G_WRAP_QUERY = HDR + """/* Public read API: only these actions reach the engine; internal write functions are unreachable. */
def ALLOWED = [dashboard: "dashboard", transactions: "transactions", investigation: "investigation", alerts: "alerts", approve: "approve"]
""" + LOOP_OPEN + """    def req = null
    try { req = new JsonSlurper().parseText(raw?.trim() ? raw : "{}") } catch (Exception e) { }
    if (!(req instanceof Map)) req = [:]
    String fn = ALLOWED[(req.action ?: "").toString()] ?: "rejected"
    String out = sqlReq(fn, JsonOutput.toJson(req))
""" + LOOP_CLOSE

G_REFRESH_SPLIT = HDR + DBROW + """/* One document per pending SID, each with its Twilio GET path. */
String sidAcct = ExecutionUtil.getDynamicProcessProperty("DPP_NONE")
""" + """for (int i = 0; i < dataContext.getDataCount(); i++) {
    InputStream is = dataContext.getStream(i)
    def res = dbResult(is.getText("UTF-8"))
    (res?.items ?: []).each { item ->
        Properties props = new Properties()
        props.setProperty("document.dynamic.userdefined.DDP_TWILIO_PATH", "/2010-04-01/Accounts/" + ACCOUNT + "/Messages/" + item.message_sid + ".json")
        dataContext.storeStream(new ByteArrayInputStream(JsonOutput.toJson(item).getBytes("UTF-8")), props)
    }
}
"""

G_BUILD_UPDATE = HDR + """/* Twilio message resource -> pi_dispatch('update_notification'). */
""" + LOOP_OPEN + """    def r = null
    try { r = new JsonSlurper().parseText(raw) } catch (Exception e) { }
    def payload = r instanceof Map && r.sid ? [message_sid: r.sid, status: r.status, error_code: r.error_code?.toString(), error_message: r.error_message] : [message_sid: "", status: ""]
    String out = sqlReq("update_notification", JsonOutput.toJson(payload))
""" + LOOP_CLOSE

SAFE_ERROR = '\'{"ok":false,"status":"ERROR","error":"The Payment Intelligence service could not process this request. It has been logged for the operations team."}\''

# ───────────── processes ─────────────
def wrapper(name, desc, wss_op, sub_id, sub_return):
    p = P()
    s1 = p.add("start", "start", "", 48, 46,
               f'<connectoraction actionType="Listen" allowDynamicCredentials="NONE" connectorType="wss" hideSettings="true" operationId="{wss_op}"><parameters/><dynamicProperties/></connectoraction>',
               [to("shape2", 240, 48)])
    p.add("catcherrors_icon", "catcherrors", "", 240, 48, trycatch(0),
          [lambda n: dp(f"{n}.dragpoint1", "shape3", 448, 56, "default", "Try"),
           lambda n: dp(f"{n}.dragpoint2", "shape4", 448, 216, "error", "Catch")])
    p.add("processcall_icon", "processcall", "Run core logic", 464, 48, processcall(sub_id, sub_return),
          [lambda n: dp(f"{n}.dragpoint1", "shape6", 896, 56, sub_return)])
    p.add("notify_icon", "notify", "Log unexpected error", 464, 208, notify_catch("PAYMENT INTEL API ERROR"), [to("shape5", 688, 208)])
    p.add("message_icon", "message", "Safe error response (no stack trace)", 688, 208, message(SAFE_ERROR), [to("shape6", 912, 48)])
    p.add("returndocuments_icon", "returndocuments", "API response", 912, 48, '<returndocuments label="API response"/>', [])
    return component(name, desc, LISTENER, p)

def sub_try_one(name, desc, pre_groovy, pre_label, action_image, action_label, action_cfg, retry, catch_title, fail_msg):
    """start [-> groovy] -> try/catch(retry) -> action -> return ; catch -> notify -> message -> return"""
    p = P()
    x = 48
    nxt = 2
    p.add("start", "start", "", 48, 46, "<passthroughaction/>", [to("shape2", 240, 48)])
    if pre_groovy:
        p.add("dataprocess_icon", "dataprocess", pre_label, 240, 48, groovy(pre_groovy), [to("shape3", 464, 48)])
        nxt, x = 3, 240
    tc_x = x + 224 if pre_groovy else 240
    t = nxt
    p.add("catcherrors_icon", "catcherrors", f"Retry {retry}x on transport faults", tc_x, 48, trycatch(retry),
          [lambda n, t=t: dp(f"{n}.dragpoint1", f"shape{t+1}", tc_x + 208, 56, "default", "Try"),
           lambda n, t=t: dp(f"{n}.dragpoint2", f"shape{t+2}", tc_x + 208, 216, "error", "Catch")])
    ax = tc_x + 224
    p.add(action_image, "connectoraction", action_label, ax, 48, action_cfg, [to(f"shape{t+4}", ax + 448, 48)])
    p.add("notify_icon", "notify", "Log transport fault", ax, 208, notify_catch(catch_title), [to(f"shape{t+3}", ax + 224, 208)])
    p.add("message_icon", "message", "Failure envelope", ax + 224, 208, message(fail_msg), [to(f"shape{t+4}", ax + 448, 48)])
    ret = p.add("returndocuments_icon", "returndocuments", "Result", ax + 448, 48, '<returndocuments label="Result"/>', [])
    return component(name, desc, SUB, p), ret

def email_sub(to_addr):
    """start -> build email -> branch(1: try/catch -> Send Notifications | catch -> log -> mark failed -> stop ; 2: result -> return)"""
    p = P()
    p.add("start", "start", "", 48, 46, "<passthroughaction/>", [to("shape2", 240, 48)])                                        #1
    p.add("dataprocess_icon", "dataprocess", "Build email (MESSAGE, EMAIL_TO, subject)", 240, 48, groovy(g_build_email(to_addr)), [to("shape3", 464, 48)])  #2
    p.add("branch_icon", "branch", "", 464, 48, '<branch numBranches="2"/>',
          [lambda n: dp(f"{n}.dragpoint1", "shape4", 656, 56, "1", "1"),
           lambda n: dp(f"{n}.dragpoint2", "shape9", 656, 376, "2", "2")])                                                       #3
    p.add("catcherrors_icon", "catcherrors", "Retry 1x on mail faults", 672, 48, trycatch(1),
          [lambda n: dp(f"{n}.dragpoint1", "shape5", 880, 56, "default", "Try"),
           lambda n: dp(f"{n}.dragpoint2", "shape6", 880, 216, "error", "Catch")])                                               #4
    p.add("processcall_icon", "processcall", "Send Notifications (email)", 896, 48,
          f'<processcall abort="true" processId="{IDS["proc_send_notif"]}" wait="true"><parameters/><returnpaths/></processcall>', [])  #5
    p.add("notify_icon", "notify", "Log mail fault", 896, 208, notify_catch("MAIL SEND FAULT"), [to("shape7", 1120, 208)])     #6
    p.add("dataprocess_icon", "dataprocess", "Mark email as failed", 1120, 208, groovy(G_EMAIL_FAIL), [to("shape8", 1344, 208)])  #7
    p.add("stop_icon", "stop", "", 1344, 208, '<stop continue="true"/>', [])                                                   #8
    p.add("dataprocess_icon", "dataprocess", "Email outcome", 672, 368, groovy(G_EMAIL_RESULT), [to("shape10", 896, 368)])       #9
    r = p.add("returndocuments_icon", "returndocuments", "Result", 896, 368, '<returndocuments label="Result"/>', [])           #10
    return component("[SUB] PI - Send Email Alert",
        "Emails the fraud/gambling alert through the shared 'Send Notifications' process (Agent Studio Processes, already deployed). Branch 1 sends inside a Try/Catch; branch 2 reports SENT or SEND_FAILED, so a mail fault never breaks the decision response.",
        SUB, p), r

def chat_sub():
    p = P()
    p.add("start", "start", "", 48, 46, "<passthroughaction/>", [to("shape2", 240, 48)])                                        #1
    p.add("dataprocess_icon", "dataprocess", "Build prompt (message + recent turns)", 240, 48, groovy(G_CHAT_PROMPT), [to("shape3", 464, 48)])  #2
    p.add("catcherrors_icon", "catcherrors", "Retry 1x on transport faults", 464, 48, trycatch(1),
          [lambda n: dp(f"{n}.dragpoint1", "shape4", 672, 56, "default", "Try"),
           lambda n: dp(f"{n}.dragpoint2", "shape6", 672, 216, "error", "Catch")])                                               #3
    p.add("aiagent_icon", "connectoraction", "Payment Intelligence Assistant", 688, 48,
          f'<connectoraction connectionId="{IDS["agent_conn"]}" connectorType="boomiai" operationId="{IDS["asst_op"]}"/>', [to("shape5", 912, 48)])  #4
    p.add("dataprocess_icon", "dataprocess", "Extract agent reply from SSE", 912, 48, groovy(G_CHAT_EXTRACT), [to("shape8", 1136, 48)])  #5
    p.add("notify_icon", "notify", "Log transport fault", 688, 208, notify_catch("ASSISTANT TRANSPORT FAULT"), [to("shape7", 912, 208)])  #6
    p.add("message_icon", "message", "Failure envelope", 912, 208,
          message('\'{"ok":false,"error":"The assistant is temporarily unavailable. Please try again."}\''), [to("shape8", 1136, 48)])  #7
    r = p.add("returndocuments_icon", "returndocuments", "Reply", 1136, 48, '<returndocuments label="Reply"/>', [])            #8
    return component("[SUB] PI - Assistant Chat",
        "Portal chat: replays the last turns as context, asks the conversational Agent Garden agent 'Payment Intelligence Assistant' (read-only tools over the Query API) and returns {ok, reply}.",
        SUB, p), r

def analyze_sub():
    p = P()
    R = 'shape17'
    p.add("start", "start", "", 48, 46, "<passthroughaction/>", [to("shape2", 240, 48)])                                        #1
    p.add("dataprocess_icon", "dataprocess", "Wrap request as pi_dispatch('ingest')", 240, 48, groovy(G_WRAP_INGEST), [to("shape3", 464, 48)])  #2
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: validate, store, build context, run rules", 464, 48, db_step(), [to("shape4", 688, 48)])  #3
    p.add("dataprocess_icon", "dataprocess", "Unwrap ingest result", 688, 48, groovy(G_UNWRAP_INGEST), [to("shape5", 912, 48)])  #4
    p.add("decision_icon", "decision", "Request valid?", 912, 48, decision_dpp("Request valid?", "DPP_VALID", "true"),
          [lambda n: dp(f"{n}.dragpoint1", "shape6", 1120, 56, "true", "True"),
           lambda n: dp(f"{n}.dragpoint2", R, 1120, 376, "false", "False")])                                                     #5
    p.add("processcall_icon", "processcall", "Ask Payment Intelligence Risk Analyst", 1136, 48,
          processcall(IDS["proc_agent_sub"], IDS["proc_agent_sub_return"]),
          [lambda n: dp(f"{n}.dragpoint1", "shape7", 1344, 56, IDS["proc_agent_sub_return"])])                                     #6
    p.add("dataprocess_icon", "dataprocess", "Agent verdict -> pi_dispatch('decide')", 1360, 48, groovy(G_BUILD_DECIDE), [to("shape8", 1584, 48)])  #7
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: decision engine + audit log", 1584, 48, db_step(), [to("shape9", 1808, 48)])  #8
    p.add("dataprocess_icon", "dataprocess", "Unwrap decision", 1808, 48, groovy(G_UNWRAP_DECIDE), [to("shape10", 2032, 48)])   #9
    p.add("decision_icon", "decision", "Fraud or gambling alert?", 2032, 48, decision_dpp("Fraud or gambling alert?", "DPP_NOTIFY", "true"),
          [lambda n: dp(f"{n}.dragpoint1", "shape11", 2240, 56, "true", "True"),
           lambda n: dp(f"{n}.dragpoint2", "shape16", 2240, 216, "false", "False")])                                              #10
    if EMAIL:
        p.add("processcall_icon", "processcall", "Send email alert (Send Notifications)", 2256, 48,
              processcall(IDS["proc_email_sub"], IDS["proc_email_sub_return"]),
              [lambda n: dp(f"{n}.dragpoint1", "shape12", 2464, 56, IDS["proc_email_sub_return"])])                                #11
        p.add("dataprocess_icon", "dataprocess", "Email result -> pi_dispatch('log_notification')", 2480, 48, groovy(G_BUILD_LOG_EMAIL), [to("shape13", 2704, 48)])  #12
    else:
        p.add("processcall_icon", "processcall", "Send WhatsApp alert (Twilio)", 2256, 48,
              processcall(IDS["proc_wa_sub"], IDS["proc_wa_sub_return"]),
              [lambda n: dp(f"{n}.dragpoint1", "shape12", 2464, 56, IDS["proc_wa_sub_return"])])                                   #11
        p.add("dataprocess_icon", "dataprocess", "Twilio result -> pi_dispatch('log_notification')", 2480, 48, groovy(G_BUILD_LOG), [to("shape13", 2704, 48)])  #12
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: notification_logs", 2704, 48, db_step(), [to("shape14", 2928, 48)])  #13
    p.add("dataprocess_icon", "dataprocess", "Decision + notification response", 2928, 48, groovy(G_UNWRAP_PLAIN), [to("shape15", 3152, 48)])  #14
    p.add("notify_icon", "notify", "Log final response", 3152, 48, notify_current("PI DECISION"), [to(R, 3376, 48)])            #15
    p.add("notify_icon", "notify", "Log decision (no alert)", 2256, 208, notify_current("PI DECISION"), [to(R, 3376, 48)])     #16
    p.add("returndocuments_icon", "returndocuments", "Response", 3376, 48, '<returndocuments label="Response"/>', [])          #17
    return component("[SUB] PI - Analyze Transaction",
        "Core workflow: validate + store + context + rules in PostgreSQL, invoke the Agent Garden agent, combine AI with deterministic rules, audit-log the decision, send an email (or WhatsApp) alert for fraud/gambling and log its delivery.",
        SUB, p), R

def query_sub():
    p = P()
    p.add("start", "start", "", 48, 46, "<passthroughaction/>", [to("shape2", 240, 48)])
    p.add("dataprocess_icon", "dataprocess", "Whitelist action -> pi_dispatch", 240, 48, groovy(G_WRAP_QUERY), [to("shape3", 464, 48)])
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: query engine", 464, 48, db_step(), [to("shape4", 688, 48)])
    p.add("dataprocess_icon", "dataprocess", "Unwrap result", 688, 48, groovy(G_UNWRAP_PLAIN), [to("shape5", 912, 48)])
    r = p.add("returndocuments_icon", "returndocuments", "Response", 912, 48, '<returndocuments label="Response"/>', [])
    return component("[SUB] PI - Query",
        "Read/approve API for the frontend: dashboard, transactions, investigation, alerts, approve (human block approval). Unknown actions are rejected.", SUB, p), r

def refresh_proc(account):
    p = P()
    split = G_REFRESH_SPLIT.replace("String sidAcct = ExecutionUtil.getDynamicProcessProperty(\"DPP_NONE\")\n", f"String ACCOUNT = {json.dumps(account)}\n")
    p.add("start", "start", "", 48, 46,
          f'<connectoraction actionType="Listen" allowDynamicCredentials="NONE" connectorType="wss" hideSettings="true" operationId="{IDS["wss_refresh"]}"><parameters/><dynamicProperties/></connectoraction>',
          [to("shape2", 240, 48)])
    p.add("message_icon", "message", "Ask for pending SIDs", 240, 48, message('\'{"query":"select pi_dispatch($1,$2) as result","params":["pending_notifications","{}"]}\''), [to("shape3", 464, 48)])
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: pending notifications", 464, 48, db_step(), [to("shape4", 688, 48)])
    p.add("dataprocess_icon", "dataprocess", "One document per SID", 688, 48, groovy(split), [to("shape5", 912, 48)])
    p.add("connectoraction_icon", "connectoraction", "Twilio: GET message status", 912, 48,
          f'<connectoraction actionType="GET" allowDynamicCredentials="NONE" connectionId="{IDS["tw_conn"]}" connectorType="officialboomi-X3979C-rest-prod" hideSettings="false" operationId="{IDS["tw_get"]}"><parameters/><dynamicProperties>'
          '<propertyvalue childKey="" key="path" name="Path" valueType="track"><trackparameter defaultValue="" propertyId="dynamicdocument.DDP_TWILIO_PATH" propertyName="Dynamic Document Property - DDP_TWILIO_PATH"/></propertyvalue>'
          '</dynamicProperties></connectoraction>', [to("shape6", 1136, 48)])
    p.add("dataprocess_icon", "dataprocess", "Status -> pi_dispatch('update_notification')", 1136, 48, groovy(G_BUILD_UPDATE), [to("shape7", 1360, 48)])
    p.add("connectoraction_icon", "connectoraction", "PostgreSQL: update notification_logs", 1360, 48, db_step(), [to("shape8", 1584, 48)])
    p.add("message_icon", "message", "One response for all updates", 1584, 48, message('\'{"ok":true,"refreshed":true}\'', combined=True), [to("shape9", 1808, 48)])
    p.add("returndocuments_icon", "returndocuments", "API response", 1808, 48, '<returndocuments label="API response"/>', [])
    return component("PI API - Refresh Alert Status",
        "POST /ws/simple/executePaymentIntelAlertRefresh: polls Twilio for every recent message still queued/sent and stores the latest delivery status in notification_logs.",
        LISTENER, p)

def write(fname, xml):
    path = os.path.join(OUT, fname)
    old = open(path).read() if os.path.exists(path) else None
    if old:  # keep platform-assigned componentId when regenerating
        import re
        m = re.search(r'componentId="([0-9a-f-]{36})"', old)
        if m: xml = xml.replace('componentId=""', f'componentId="{m.group(1)}"', 1)
    open(path, "w").write(xml)
    print("wrote", fname)

have = lambda *k: all(IDS.get(x) for x in k)

if have("tw_conn", "tw_post"):
    xml, ret = sub_try_one("[SUB] PI - Send WhatsApp Alert",
        "Sends the WhatsApp alert through Twilio. Only the Twilio call is inside the Try/Catch, so a retry can never duplicate database writes.",
        g_build_whatsapp(os.environ["WA_TO"], os.environ["WA_FROM"], os.environ.get("WA_CONTENT_SID", "")), "Build Twilio form body (To, From, " + ("ContentSid" if os.environ.get("WA_CONTENT_SID") else "Body") + ")",
        "connectoraction_icon", "Twilio: POST WhatsApp message",
        f'<connectoraction actionType="POST" allowDynamicCredentials="NONE" connectionId="{IDS["tw_conn"]}" connectorType="officialboomi-X3979C-rest-prod" hideSettings="false" operationId="{IDS["tw_post"]}"><parameters/><dynamicProperties/></connectoraction>',
        2, "TWILIO TRANSPORT FAULT", '\'{"status":"SEND_FAILED","message":"Twilio unreachable after 3 attempts (see process log)","attempts":3}\'')
    write("SUB_PI_Send_WhatsApp_Alert.xml", xml); print("  return shape:", ret)

EMAIL = have("proc_email_sub", "proc_email_sub_return")
if have("proc_send_notif") and os.environ.get("ALERT_EMAIL_TO"):
    xml, ret = email_sub(os.environ["ALERT_EMAIL_TO"])
    write("SUB_PI_Send_Email_Alert.xml", xml); print("  return shape:", ret)

if have("agent_conn", "agent_op"):
    xml, ret = sub_try_one("[SUB] PI - Invoke Risk Analyst Agent",
        "Calls the Agent Garden agent 'Payment Intelligence Risk Analyst' (structured mode). Transport faults retry once, then return a success=false envelope so the decision engine falls back to rules + manual review.",
        None, None, "aiagent_icon", "Payment Intelligence Risk Analyst",
        f'<connectoraction connectionId="{IDS["agent_conn"]}" connectorType="boomiai" operationId="{IDS["agent_op"]}"/>',
        1, "AGENT TRANSPORT FAULT", '\'{"success":false,"error":"AGENT_TRANSPORT_FAULT"}\'')
    write("SUB_PI_Invoke_Risk_Analyst_Agent.xml", xml); print("  return shape:", ret)

if have("db_conn", "db_op"):
    xml, ret = query_sub()
    write("SUB_PI_Query.xml", xml); print("  return shape:", ret)
    if have("proc_query_sub", "wss_query"):
        write("API_PI_Query.xml", wrapper("PI API - Query",
            "POST /ws/simple/executePaymentIntelQuery {action: dashboard|transactions|investigation|alerts|approve, ...}.",
            IDS["wss_query"], IDS["proc_query_sub"], IDS["proc_query_sub_return"]))
    if have("proc_agent_sub") and (EMAIL or have("proc_wa_sub")):
        xml, ret = analyze_sub()
        write("SUB_PI_Analyze_Transaction.xml", xml); print("  return shape:", ret)
        if have("proc_analyze_sub", "wss_analyze"):
            write("API_PI_Analyze_Transaction.xml", wrapper("PI API - Analyze Transaction",
                "POST /ws/simple/createPaymentAnalysis with a transaction JSON. Returns classification, risk_score, confidence, detected_indicators, explanation, recommended_action and the WhatsApp notification result.",
                IDS["wss_analyze"], IDS["proc_analyze_sub"], IDS["proc_analyze_sub_return"]))
    if have("tw_conn", "tw_get", "wss_refresh"):
        write("API_PI_Refresh_Alert_Status.xml", refresh_proc(os.environ["TW_ACCOUNT"]))

if have("agent_conn", "asst_op"):
    xml, ret = chat_sub()
    write("SUB_PI_Assistant_Chat.xml", xml); print("  return shape:", ret)
    if have("proc_chat_sub", "wss_chat"):
        write("API_PI_Assistant_Chat.xml", wrapper("PI API - Assistant Chat",
            "POST /ws/simple/executePaymentIntelAssistantChat {message, history[]} -> {ok, reply}. Used by the portal's AI assistant panel.",
            IDS["wss_chat"], IDS["proc_chat_sub"], IDS["proc_chat_sub_return"]))

# ───────────── SNAP (BI Standar Nasional Open API Pembayaran) Transfer Intrabank ─────────────
# Request : headers X-TIMESTAMP, X-SIGNATURE, X-PARTNER-ID, X-EXTERNAL-ID, CHANNEL-ID
#           body    {"encryptedKey","iv","encryptedData"}  (hybrid: RSA-OAEP-SHA256 wraps an AES-256-GCM key)
#           X-SIGNATURE = Base64(SHA256withRSA(partnerPrivateKey,
#                         "POST:/v1.0/transfer-intrabank:" + lowerhex(SHA-256(body as sent)) + ":" + X-TIMESTAMP))
# Response: body    {"responseCode","responseMessage","encryptedKey","iv","encryptedData"} encrypted for the partner,
#           headers X-TIMESTAMP + X-SIGNATURE signed with the Boomi private key over the same string-to-sign.
# Keys are read from DPPs that are declared as environment extensions (values never live in the XML).
SNAP_PATH = "/v1.0/transfer-intrabank"
SNAP_DPPS = ["DPP_SNAP_PARTNER_ID", "DPP_SNAP_PARTNER_PUBLIC_KEY", "DPP_SNAP_BOOMI_PRIVATE_KEY"]
SNAP_HDR = HDR + """import java.security.*
import java.security.spec.*
import javax.crypto.Cipher
import javax.crypto.spec.*
import java.time.*
import java.time.format.DateTimeFormatter
String PATH = '""" + SNAP_PATH + """'
def dpp = { String n -> (ExecutionUtil.getDynamicProcessProperty(n) ?: '').trim() }
def b64d = { String s -> Base64.decoder.decode(s.replaceAll(/-----[A-Z ]+-----|\\s/, '')) }
def b64e = { byte[] b -> Base64.encoder.encodeToString(b) }
def pubKey = { String s -> KeyFactory.getInstance('RSA').generatePublic(new X509EncodedKeySpec(b64d(s))) }
def privKey = { String s -> KeyFactory.getInstance('RSA').generatePrivate(new PKCS8EncodedKeySpec(b64d(s))) }
def oaep = new OAEPParameterSpec('SHA-256', 'MGF1', MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT)
def hex256 = { String s -> MessageDigest.getInstance('SHA-256').digest(s.getBytes('UTF-8')).encodeHex().toString() }
def toSign = { String body, String ts -> 'POST:' + PATH + ':' + hex256(body) + ':' + ts }
"""

G_SNAP_OPEN = SNAP_HDR + """/* SNAP request: check mandatory headers, partner, timestamp window, SHA256withRSA signature, then decrypt
   and map the SNAP transfer-intrabank body to the Payment Intelligence analyze input. Any failure -> SNAP error. */
def hdr = { Properties p, String n -> def k = p.stringPropertyNames().find { it.toLowerCase().endsWith('inheader_' + n.toLowerCase()) }; k ? (p.getProperty(k) ?: '').trim() : '' }
def reject = { String code, String msg -> ExecutionUtil.setDynamicProcessProperty('DPP_SNAP_OK', 'false', false); JsonOutput.toJson([responseCode: code, responseMessage: msg]) }
""" + LOOP_OPEN + """    String out
    // Boomi Cloud's shared web server drops custom X-* headers, so a SNAP gateway may forward them as
    // {"snapHeaders":{...},"snapBody":"<raw body exactly as received>"}. Real inheader_* values win when present.
    String body = raw
    def gw = [:]
    try {
        def w = new JsonSlurper().parseText(raw)
        if (w instanceof Map && w.snapHeaders instanceof Map && w.snapBody instanceof String) {
            gw = w.snapHeaders.collectEntries { k, v -> [k.toString().toLowerCase(), v.toString().trim()] }; body = w.snapBody
        }
    } catch (Exception e) { }
    def H = { String n -> hdr(props, n) ?: (gw[n.toLowerCase()] ?: '') }
    String ts = H('X-TIMESTAMP'), sig = H('X-SIGNATURE'), partner = H('X-PARTNER-ID'), ext = H('X-EXTERNAL-ID')
    def missing = [['X-TIMESTAMP', ts], ['X-SIGNATURE', sig], ['X-PARTNER-ID', partner], ['X-EXTERNAL-ID', ext]].find { !it[1] }
    if (missing) {
        out = reject('4011700', 'Unauthorized. Missing header ' + missing[0])
    } else if (!dpp('DPP_SNAP_PARTNER_PUBLIC_KEY') || !dpp('DPP_SNAP_BOOMI_PRIVATE_KEY')) {
        out = reject('5001700', 'General Error')   // keys not configured in environment extensions
    } else if (partner != dpp('DPP_SNAP_PARTNER_ID')) {
        out = reject('4011700', 'Unauthorized. Unknown partner')
    } else {
        OffsetDateTime t = null
        try { t = OffsetDateTime.parse(ts) } catch (Exception e) { }
        boolean ok = false
        if (t != null && Math.abs(Duration.between(t.toInstant(), Instant.now()).getSeconds()) <= 300) {
            try {
                Signature v = Signature.getInstance('SHA256withRSA'); v.initVerify(pubKey(dpp('DPP_SNAP_PARTNER_PUBLIC_KEY')))
                v.update(toSign(body, ts).getBytes('UTF-8')); ok = v.verify(b64d(sig))
            } catch (Exception e) { ok = false }
        }
        if (t == null) out = reject('4011700', 'Unauthorized. Invalid X-TIMESTAMP')
        else if (!ok) out = reject('4011700', 'Unauthorized. Signature')
        else {
            def req = null
            try {
                def env = new JsonSlurper().parseText(body)
                Cipher r = Cipher.getInstance('RSA/ECB/OAEPPadding'); r.init(Cipher.DECRYPT_MODE, privKey(dpp('DPP_SNAP_BOOMI_PRIVATE_KEY')), oaep)
                byte[] k = r.doFinal(b64d(env.encryptedKey))
                Cipher a = Cipher.getInstance('AES/GCM/NoPadding'); a.init(Cipher.DECRYPT_MODE, new SecretKeySpec(k, 'AES'), new GCMParameterSpec(128, b64d(env.iv)))
                req = new JsonSlurper().parseText(new String(a.doFinal(b64d(env.encryptedData)), 'UTF-8'))
            } catch (Exception e) { req = null }
            if (!(req instanceof Map)) out = reject('4001701', 'Invalid Field Format encryptedData')
            else {
                def ai = req.additionalInfo instanceof Map ? req.additionalInfo : [:]
                def need = [['partnerReferenceNo', req.partnerReferenceNo], ['amount.value', req.amount?.value], ['amount.currency', req.amount?.currency],
                            ['beneficiaryAccountNo', req.beneficiaryAccountNo], ['sourceAccountNo', req.sourceAccountNo], ['additionalInfo.paymentId', ai.paymentId]].find { !it[1] }
                if (need) out = reject('4001702', 'Invalid Mandatory Field ' + need[0])
                else if (req.amount.currency != 'IDR') out = reject('4001701', 'Invalid Field Format amount.currency')
                else {
                    String ref = req.partnerReferenceNo.toString().toUpperCase()
                    ExecutionUtil.setDynamicProcessProperty('DPP_SNAP_OK', 'true', false)
                    ExecutionUtil.setDynamicProcessProperty('DPP_SNAP_REQUEST', JsonOutput.toJson(req), false)
                    out = JsonOutput.toJson([transaction_id: ref.startsWith('TX-') ? ref : 'TX-' + ref, payment_id: ai.paymentId,
                        amount: req.amount.value, currency: 'IDR', channel: 'BANK_TRANSFER', counterparty_account: req.beneficiaryAccountNo, source_account: req.sourceAccountNo,
                        merchant_id: ai.merchantId, device_id: ai.deviceId, ip_country: ai.ipCountry, description: req.remark,
                        transaction_time: req.transactionDate,
                        // stored in snap_requests by pi_ingest before the AI decision is made
                        snap: [partner_reference_no: ref, partner_id: partner, external_id: ext, channel_id: H('CHANNEL-ID'), request: req]
                        ].findAll { it.value != null && it.value != '' })
                }
            }
        }
    }
""" + LOOP_CLOSE

G_SNAP_RESULT = HDR + """/* Payment Intelligence decision -> SNAP transfer-intrabank response (service code 17). */
""" + LOOP_OPEN + """    def res = new JsonSlurper().parseText(raw)
    def req = new JsonSlurper().parseText(ExecutionUtil.getDynamicProcessProperty('DPP_SNAP_REQUEST'))
    def base = [partnerReferenceNo: req.partnerReferenceNo, amount: req.amount, beneficiaryAccountNo: req.beneficiaryAccountNo,
                sourceAccountNo: req.sourceAccountNo, transactionDate: req.transactionDate]
    def m
    if (res.valid == false) {
        def errs = res.errors ?: [res.error]
        boolean dup = errs.any { it.toString().contains('already exists') }
        m = [responseCode: dup ? '4091701' : '4001701', responseMessage: dup ? 'Conflict. Duplicate partnerReferenceNo' : 'Invalid Field Format'] + base + [additionalInfo: [errors: errs]]
    } else if (!res.recommended_action) {
        m = [responseCode: '5001700', responseMessage: 'General Error'] + base
    } else {
        def map = [APPROVE: ['2001700', 'Successful', '00'], REVIEW: ['2021700', 'Request In Progress', '03'],
                   FLAG: ['2021700', 'Request In Progress', '03'], BLOCK: ['4031703', 'Suspected Fraud', '06']]
        def c = map[res.recommended_action.toString()] ?: ['5001700', 'General Error', '06']
        m = [responseCode: c[0], responseMessage: c[1], referenceNo: res.transaction_id] + base + [latestTransactionStatus: c[2],
             additionalInfo: [riskAssessment: [classification: res.classification, riskScore: res.risk_score, confidence: res.confidence,
                 recommendedAction: res.recommended_action, indicators: res.detected_indicators, explanation: res.explanation,
                 aiVerdict: res.ai ? [classification: res.ai.classification, riskScore: res.ai.risk_score, recommendedAction: res.ai.recommended_action, status: res.ai.status] : null,
                 ruleScore: res.rules?.rule_score, ruleOverride: res.rules?.override, requiresHumanApproval: res.requires_human_approval,
                 investigationRef: res.investigation_ref, transactionStatus: res.transaction_status,
                 decisionMethod: res.decision_method, pattern: res.pattern],
                 notification: [channel: res.notification?.channel, status: res.notification?.status]]]
    }
    String out = JsonOutput.toJson(m)
""" + LOOP_CLOSE

G_SNAP_SEAL = SNAP_HDR + """/* Encrypt the SNAP response for the partner (RSA-OAEP + AES-256-GCM) and sign it with the Boomi private key.
   responseCode/responseMessage stay in clear text so gateways can route without the key. */
""" + LOOP_OPEN + """    def plain = new JsonSlurper().parseText(raw)
    String out
    try {
        byte[] k = new byte[32], iv = new byte[12]; SecureRandom rnd = new SecureRandom(); rnd.nextBytes(k); rnd.nextBytes(iv)
        Cipher a = Cipher.getInstance('AES/GCM/NoPadding'); a.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(k, 'AES'), new GCMParameterSpec(128, iv))
        byte[] ct = a.doFinal(raw.getBytes('UTF-8'))
        Cipher r = Cipher.getInstance('RSA/ECB/OAEPPadding'); r.init(Cipher.ENCRYPT_MODE, pubKey(dpp('DPP_SNAP_PARTNER_PUBLIC_KEY')), oaep)
        out = JsonOutput.toJson([responseCode: plain.responseCode, responseMessage: plain.responseMessage,
                                 encryptedKey: b64e(r.doFinal(k)), iv: b64e(iv), encryptedData: b64e(ct)])
        String ts = OffsetDateTime.now(ZoneOffset.ofHours(7)).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX"))
        Signature s = Signature.getInstance('SHA256withRSA'); s.initSign(privKey(dpp('DPP_SNAP_BOOMI_PRIVATE_KEY')))
        s.update(toSign(out, ts).getBytes('UTF-8'))
        props.setProperty('document.dynamic.userdefined.outheader_X-TIMESTAMP', ts)
        props.setProperty('document.dynamic.userdefined.outheader_X-SIGNATURE', b64e(s.sign()))
    } catch (Exception e) {   // keys missing/invalid: unencrypted, unsigned general error (no detail leaked)
        out = JsonOutput.toJson([responseCode: '5001700', responseMessage: 'General Error'])
    }
""" + LOOP_CLOSE

def snap_proc():
    """start(WSS) -> try/catch -> open(verify+decrypt) -> valid? -> analyze sub -> SNAP result -> seal -> return
                                                  invalid -> seal ; catch -> notify -> 5001700 -> seal(2) -> return"""
    p = P()
    p.add("start", "start", "", 48, 46,
          f'<connectoraction actionType="Listen" allowDynamicCredentials="NONE" connectorType="wss" hideSettings="true" operationId="{IDS["wss_snap"]}"><parameters/><dynamicProperties/></connectoraction>',
          [to("shape2", 240, 48)])                                                                                                 #1
    p.add("catcherrors_icon", "catcherrors", "", 240, 48, trycatch(0),
          [lambda n: dp(f"{n}.dragpoint1", "shape3", 448, 56, "default", "Try"),
           lambda n: dp(f"{n}.dragpoint2", "shape9", 448, 376, "error", "Catch")])                                                #2
    p.add("dataprocess_icon", "dataprocess", "SNAP: verify signature + decrypt request", 464, 48, groovy(G_SNAP_OPEN), [to("shape4", 688, 48)])  #3
    p.add("decision_icon", "decision", "Signature & payload valid?", 688, 48, decision_dpp("Signature & payload valid?", "DPP_SNAP_OK", "true"),
          [lambda n: dp(f"{n}.dragpoint1", "shape5", 896, 56, "true", "True"),
           lambda n: dp(f"{n}.dragpoint2", "shape7", 896, 216, "false", "False")])                                                 #4
    p.add("processcall_icon", "processcall", "Analyze transaction (PI core)", 912, 48,
          processcall(IDS["proc_analyze_sub"], IDS["proc_analyze_sub_return"]),
          [lambda n: dp(f"{n}.dragpoint1", "shape6", 1120, 56, IDS["proc_analyze_sub_return"])])                                     #5
    p.add("dataprocess_icon", "dataprocess", "Decision -> SNAP response", 1136, 48, groovy(G_SNAP_RESULT), [to("shape7", 1360, 48)])  #6
    p.add("dataprocess_icon", "dataprocess", "SNAP: encrypt + sign response", 1360, 48, groovy(G_SNAP_SEAL), [to("shape8", 1584, 48)])  #7
    p.add("returndocuments_icon", "returndocuments", "SNAP response", 1584, 48, '<returndocuments label="SNAP response"/>', [])  #8
    p.add("notify_icon", "notify", "Log unexpected error", 464, 368, notify_catch("PI SNAP API ERROR"), [to("shape10", 688, 368)])  #9
    p.add("message_icon", "message", "SNAP general error", 688, 368,
          message('\'{"responseCode":"5001700","responseMessage":"General Error"}\''), [to("shape11", 912, 368)])                  #10
    p.add("dataprocess_icon", "dataprocess", "SNAP: encrypt + sign error", 912, 368, groovy(G_SNAP_SEAL), [to("shape8", 1584, 48)])  #11
    xml = component("PI API - SNAP Transfer Intrabank",
        "SNAP (BI) Transfer Intrabank: POST /ws/simple/executePaymentIntelSnapTransfer. Verifies X-SIGNATURE (SHA256withRSA), decrypts the "
        "RSA-OAEP/AES-256-GCM body, runs the Payment Intelligence analysis and returns an encrypted, signed SNAP response "
        "(2001700 approve, 2021700 review, 4031703 suspected fraud). Keys come from environment extensions.", LISTENER, p)
    ov = "".join(f'<PropertyOverride name="{d}"/>' for d in SNAP_DPPS)
    return xml.replace("<bns:processOverrides/>", f'<bns:processOverrides><Overrides xmlns=""><Properties>{ov}</Properties></Overrides></bns:processOverrides>')

if have("wss_snap", "proc_analyze_sub", "proc_analyze_sub_return"):
    write("API_PI_SNAP_Transfer_Intrabank.xml", snap_proc())
