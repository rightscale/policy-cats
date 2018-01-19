name "Policies Mailer Package"
rs_ca_ver 20161221
short_description "Provides functionality for uber cats"
package "mailer"
import "sys_log"

########################################################
#  USAGE
#
#  This package provides definitions to support the policies_mailer service
#
#  EXAMPLE
#  -----
#  To define which groups can launch this cat, use the following code.
#  ```
#  import 'mailer'
#  call mailer.create_csv_with_columns(["column-a","column-b"])
#  ```
#
#  ------
# Append to the audit entry detail for this process


define delete_csv($endpoint,$filename) do
  call start_debugging()
  sub on_error: stop_debugging() do
    $endpoint = $endpoint + "/api/csv/" + $filename
    $response = http_delete(
      url: $endpoint,
      headers: {"X-Api-Version": "1.0"}
    )
  end
end

define create_csv_with_columns($endpoint,$columns) return $filename do
  task_label("creating csv file")
  $filename = ""
  $endpoint = $endpoint + "/api/csv/"
  call sys_log.detail("endpoint" + $endpoint)
  call start_debugging()
  sub on_error: stop_debugging() do    
    $response = http_post(
      url: $endpoint,
      headers: {"X-Api-Version": "1.0"},
      body: { "data": [$columns] }
    )
    $filename = $response["body"]["file"]
    $$mailer_filename = $filename
  end
end

define update_csv_with_rows($endpoint,$filename,$rows) return $filename do
  task_label("csv:" + $filename + " name: " + $rows[0])
  call start_debugging()
  $filename = ""
  sub on_error: stop_debugging() do
    $endpoint = $endpoint + "/api/csv/" + $filename
    $response = http_put(
      url: $endpoint,
      headers: {"X-Api-Version": "1.0"},
      body: { "data": [$rows] }
    )
    $filename = $response["body"]["file"]
  end
end

define send_html_email($endpoint,$to, $from, $subject, $html,$filename, $encoding) return $response do
  task_label("Sending email")
  $endpoint = $endpoint + "/api/mail"
  $response = ""
  call start_debugging()
  sub on_error: stop_debugging() do
    $response = http_post(
      url: $endpoint,
      headers: {"X-Api-Version": "1.0"},
      body: {
      "to": $to,
      "from": $from,
      "subject": $subject,
      "body": $html,
      "attachment": $filename,
      "encoding": $encoding
      }
    )
  end
end

define create_csv_and_send_email($endpoint,$to,$from,$subject,$html,$two_dimensional_array_of_csv_data,$encoding) return $response do
  task_label("creating csv and send email")
  $endpoint = $endpoint + "/api/csv/"
  $response = ""
  call start_debugging()
  sub on_error:stop_debugging() do
    $response = http_post(
      url: $endpoint,
      headers: {"X-Api-Version": "1.0"},
      body: { "data": $two_dimensional_array_of_csv_data }
    )
    $filename = $response["body"]["file"]
    $$mailer_filename = $filename
  end
  call send_html_email($endpoint,$to, $from, $subject, $html,$filename, $encoding) retrieve $response
end

define start_debugging() do
  if $$debugging == false || logic_and($$debugging != false, $$debugging != true)
    initiate_debug_report()
    $$debugging = true
  end
end

define stop_debugging() do
  if $$debugging == true
    $debug_report = complete_debug_report()
    call sys_log.detail($debug_report)
    $$debugging = false
  end
end