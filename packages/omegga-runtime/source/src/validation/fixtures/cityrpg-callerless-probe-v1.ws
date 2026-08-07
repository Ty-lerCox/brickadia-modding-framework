/// Isolated-test-only callerless command probe.
/// This graph performs no gameplay mutation and never touches the sender.

let MAX_PROBE_REQUESTS = 64
array acknowledgedRequestIds: string[]

on ChatCommand("cityrpgRemote", "Callerless transport probe", unusedController, arguments) {
  let command = arguments.Split(":")
  let action = command.Left.Trim().ToLower()
  let requestId = command.Right.Trim()
  let validRequest = requestId.Length() >= 8 && requestId.Length() <= 64 && !requestId.Contains(":") && !requestId.Contains(" ") && !requestId.Contains("\\n") && !requestId.Contains("\\r")

  if action == "callerlessprobev1" && validRequest {
    let existing = acknowledgedRequestIds.find(requestId)
    if !existing.Found && acknowledgedRequestIds.length() < MAX_PROBE_REQUESTS {
      acknowledgedRequestIds.push(requestId)
      PrintToConsole("callerless_probe_ack:${requestId}")
    }
  }
}
