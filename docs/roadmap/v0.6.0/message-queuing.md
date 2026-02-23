# Message Queuing

Users can't send messages while an agent is working between converse cycles.

## Queued Messages

Browser allows typing or recording at any time. If the agent is busy, the hub queues the message and delivers it on the next `converse(wait_for_response=true)` call, prepended with a timestamp.

## Queue Indicator

Browser shows a badge on the session tab (e.g., "Sky (2)") and renders queued messages with dimmed styling until delivered.

## `check_inbox` Tool

Non-blocking poll for pending messages — from the user or other agents. Lets agents adapt mid-task without waiting for the next converse cycle. Messages also arrive automatically with each `converse` call, so polling is optional.
