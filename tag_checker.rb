#Copyright 2017 RightScale
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.


#RightScale Cloud Application Template (CAT)

# DESCRIPTION
# Uses RightScale Cloud Language (RCL) to check all instances in an account for a given tag key and reports back which
# servers or instances are missing the tag.
#
# Future Plans
#   Run continuously checking periodically

# Required prolog
name 'Tag Checker'
rs_ca_ver 20160622
short_description "![Tag](https://s3.amazonaws.com/rs-pft/cat-logos/tag.png)\n
Check for a tag and report which instances are missing it."
long_description "Uses RCL to check for a tag and report which instances are missing it."

##################
# User inputs    #
##################
parameter "param_tag_key" do
  category "User Inputs"
  label "Tags' Namespace:Keys List"
  type "string"
  description "Comma-separated list of Tags' Namespace:Keys to audit. For example: \"ec2:project_code\" or \"bu:id\""
  default "costcenter:id"
  allowed_pattern '^([a-zA-Z0-9-_]+:[a-zA-Z0-9-_]+,*)+$'
end

parameter "parameter_check_frequency" do
  category "User Inputs"
  label "Minutes between each check."
  type "number"
  default 5
  min_value 5
end

parameter "parameter_cloud" do
  category "User Inputs"
  label "Cloud to look in (enter cloud href to limit scope)"
  type "string"
  default "All"
end

################################
# Outputs returned to the user #
################################
output "output_bad_instances" do
  label "Instances Missing Specified Tag(s)"
  category "Output"
  description "Instances missing the specified tag(s)."
end


####################
# OPERATIONS       #
####################
operation "launch" do
  description "Check for tags!"
  definition "launch_tag_checker"
  output_mappings do {
    $output_bad_instances => $bad_instances,
  } end
end

operation "checktags" do
  description "Check for tags!"
  definition "tag_checker"
  output_mappings do {
    $output_bad_instances => $bad_instances,
  } end
end

##########################
# DEFINITIONS (i.e. RCL) #
##########################
# Go through and find improperly tagged instances
define launch_tag_checker($param_tag_key, $parameter_check_frequency, $parameter_cloud) return $bad_instances do

  # add deployment tags for the parameters and then tell tag_checker to go
  rs_cm.tags.multi_add(resource_hrefs: [@@deployment.href], tags: [join(["tagchecker:tag_key=",$param_tag_key])])
  rs_cm.tags.multi_add(resource_hrefs: [@@deployment.href], tags: [join(["tagchecker:check_frequency=",$parameter_check_frequency])])
  rs_cm.tags.multi_add(resource_hrefs: [@@deployment.href], tags: [join(["tagchecker:cloud_scope=",$parameter_cloud])])

  call tag_checker() retrieve $bad_instances
end

# Do the actual work of looking at the tags and identifying bad instances.
define tag_checker() return $bad_instances do

  # Get the stored parameters from the deployment tags
  $tag_key = ""
  $check_frequency = 5
  $cloud_scope = ""

  # retrieve tags on current deployment
  call get_tags_for_resource(@@deployment) retrieve $tags_on_deployment
  $href_tag = map $current_tag in $tags_on_deployment return $tag do
    if $current_tag =~ "(tagchecker:tag_key)"
      $tag_key = last(split($current_tag,"="))
    elsif $current_tag =~ "(tagchecker:check_frequency)"
      $check_frequency = to_n(last(split($current_tag,"=")))
    elsif $current_tag =~ "(tagchecker:cloud_scope)"
      $cloud_scope = last(split($current_tag,"="))
    end
  end


  if $cloud_scope == "All"
    @instances_operational = rs_cm.instances.get(filter: ["state==operational"])
    @instances_provisioned = rs_cm.instances.get(filter: ["state==provisioned"])
    @instances_running = rs_cm.instances.get(filter: ["state==running"])
  else
    @instances_operational = rs_cm.clouds.get(href: $cloud_scope).instances(filter: ["state==operational"])
    @instances_provisioned = rs_cm.clouds.get(href: $cloud_scope).instances(filter: ["state==provisioned"])
    @instances_running = rs_cm.clouds.get(href: $cloud_scope).instances(filter: ["state==running"])
  end

  @instances = @instances_operational + @instances_provisioned + @instances_running

  $instances_hrefs = to_object(@instances)["hrefs"]

  # call logger(@@deployment, "All instance hrefs:", to_s($instances_hrefs))
  $$bad_instances_array=[]

  foreach $hrefs in $instances_hrefs do
  $instances_tags = rs_cm.tags.by_resource(resource_hrefs: [$hrefs])
  $tag_info_array = $instances_tags[0]
  # Loop through the tag info array and find any entries which DO NOT reference the tag(s) in question.
  $param_tag_keys_array = split($tag_key, ",")  # make the parameter list an array so I can search stuff

          foreach $tag_info_hash in $tag_info_array do

                  # Create an array of the tags' namespace:key parts
                  $tag_entry_ns_key_array=[]
                  foreach $tag_entry in $tag_info_hash["tags"] do
                    $tag_entry_ns_key_array << split($tag_entry["name"],"=")[0]
                  end

          # See if the desired keys are in the found tags and if not take note of the improperly tagged instances
          if logic_not(contains?($tag_entry_ns_key_array, $param_tag_keys_array))

              foreach $resource in $tag_info_hash["links"] do
                $$bad_instances_array << $resource["href"]
              end

          end
        end


        $$bad_instances = to_s($$bad_instances_array)
  end
      # Send an alert email if there is at least one improperly tagged instance
      if logic_not(empty?($$bad_instances_array))
        call send_tags_alert_email($tag_key,$$bad_instances)
      end
end


# Returns the RightScale shard for the account the given CAT is launched in.
define find_shard() return $shard_number do
  call find_account_number() retrieve $account_number
  $account = rs_cm.get(href: "/api/accounts/" + $account_number)
  $shard_number = last(split(select($account[0]["links"], {"rel":"cluster"})[0]["href"],"/"))
end

define find_account_name() return $account_name do
  $session_info = rs_cm.sessions.get(view: "whoami")
  $acct_link = select($session_info[0]["links"], {rel: "account"})
  $acct_href = $acct_link[0]["href"]
  $account_name = rs_cm.get(href: $acct_href).name
end

define get_tags_for_resource(@resource) return $tags do
# Returns all tags for a specified resource. Assumes that only one resource
# is passed in, and will return tags for only the first resource in the collection.

# @param @resource [ResourceCollection] a ResourceCollection containing only a
#   single resource for which to return tags

# @return $tags [Array<String>] an array of tags assigned to @resource
  $tags = []
  $tags_response = rs_cm.tags.by_resource(resource_hrefs: [@resource.href])
  $inner_tags_ary = first(first($tags_response))["tags"]
  $tags = map $current_tag in $inner_tags_ary return $tag do
    $tag = $current_tag["name"]
  end
  $tags = $tags
end

define send_tags_alert_email($tags,$bad_instances) do

  # Get account ID
  call find_account_name() retrieve $account_name

  # Build email
  $deployment_description_array = lines(@@deployment.description)
  $to="edwin@rightscale.com"

  $message = "The following instances are missing tags, " + $tags + ":\n " + $bad_instances

  #$to = gsub($to,"@","%40")
  $subject = "Tag Checker Policy: "
  $from = "policy-cat@services.rightscale.com"

  $body_html = '<img src="https://assets.rightscale.com/735ca432d626b12f75f7e7db6a5e04c934e406a8/web/images/logo.png" style="width:220px" />
              <p>Some info here</p>'

  foreach $instance in $bad_instances do
    $$table_rows = ''
    @instance = rs_cm.get(href: "/api/clouds/1/instances/C08HNN6HOM02P")
    $instance_name = @instance.name
    $instance_state = @instance.state
    $$table_rows = $$table_rows + '<table><tr><th>' + $instance_name + '</th><th>' + $instance_state + '</th><th>asdfasdfasdfasd</tr>'
  end


  $body_html = $body_html + $$table_rows
  #'<table><tr><th>Instance Name</th><th>State</th><th>Link</tr>' + $table_rows + '</table>'

  $footer_text = 'This report was automatically generated by a policy tag checker your organization has defined in RightScale.'

  call get_html_template() retrieve $html_template
  # render the template
  $html = $html_template
  $html = gsub($html, '{{title}}', $subject)
  $html = gsub($html, '{{body}}', $body_html)
  $html = gsub($html, '{{footer_text}}', $footer_text)

  call send_html_email($to, $from, $subject, $html) retrieve $response

  if $response['code'] != 200
    raise 'Failed to send email report: ' + to_s($response)
  end

end


define send_html_email($to, $from, $subject, $html) return $response do
  $mailgun_endpoint = 'http://smtp.services.rightscale.com/v3/services.rightscale.com/messages'

  $to = gsub($to, "@", "%40")
  $from = gsub($from, "@", "%40")

  # escape ampersands used in html encoding
  $html = gsub($html, "&", "%26")

  $post_body = 'from=' + $from + '&to=' + $to + '&subject=' + $subject + '&html=' + $html

  $response = http_post(
    url: $mailgun_endpoint,
    headers: {"content-type": "application/x-www-form-urlencoded"},
    body: $post_body
  )
end


# Returns the RightScale account number in which the CAT was launched.
define find_account_number() return $account_id do
  $session = rs_cm.sessions.index(view: "whoami")
  $account_id = last(split(select($session[0]["links"], {"rel":"account"})[0]["href"],"/"))
end


define get_html_template() return $html_template do
  $response = http_get(
    url: 'https://raw.githubusercontent.com/rs-services/policy-cats/master/templates/email_template.html'
  )
  $html_template = $response['body']
end

define get_server_access_link($instance_href) return $server_access_link_root do

    call find_shard() retrieve $shard
    call find_account_number() retrieve $account_number
    $rs_endpoint = "https://us-"+$shard+".rightscale.com"

    $instance_id = last(split($instance_href, "/"))
    $response = http_get(
      url: $rs_endpoint+"/api/instances?ids="+$instance_id,
      headers: {
      "X-Api-Version": "1.6",
      "X-Account": $account_number
      }
     )
     $instances = $response["body"]
     $instance_of_interest = select($instances, { "href" : $instance_href })[0]
     $legacy_id = $instance_of_interest["legacy_id"]
     $data = split($instance_href, "/")
     $cloud_id = $data[3]
     $server_access_link_root = "https://my.rightscale.com/acct/" + $account_number + "/clouds/" + $cloud_id + "/instances/" + $legacy_id
 end