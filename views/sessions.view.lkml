view: sessions {
  derived_table: {
    datagroup_trigger: generated_model_default_datagroup
    partition_keys: ["session_date"]
    cluster_keys: ["session_date"]
    increment_key: "session_date"
    increment_offset: 3
    sql: with
-- obtains a list of sessions, uniquely identified by the table date, ga_session_id event parameter, ga_session_number event parameter, and the user_pseudo_id.
session_list_with_event_history as (
  select timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+'))) session_date
      ,  (select value.int_value from UNNEST(events.event_params) where key = "ga_session_id") ga_session_id
      ,  (select value.int_value from UNNEST(events.event_params) where key = "ga_session_number") ga_session_number
      ,  events.user_pseudo_id
      -- unique key for session:
      ,  timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+')))||(select value.int_value from UNNEST(events.event_params) where key = "ga_session_id")||(select value.int_value from UNNEST(events.event_params) where key = "ga_session_number")||events.user_pseudo_id sl_key
      -- this array of structs captures all events in a session as a single nested element
      ,  ARRAY_AGG(STRUCT(timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+')))
                          ||(select value.int_value from UNNEST(events.event_params) where key = "ga_session_id")
                          ||(select value.int_value from UNNEST(events.event_params) where key = "ga_session_number")
                          ||events.user_pseudo_id as sl_key
                        , event_date
                        , event_timestamp
                        , event_name
                        , event_params
                        , event_previous_timestamp
                        , event_value_in_usd
                        , event_bundle_sequence_id
                        , event_server_timestamp_offset
                        , user_id
                        , user_pseudo_id
                        , user_properties
                        , user_first_touch_timestamp
                        , user_ltv
                        , device
                        , geo
                        , app_info
                        , traffic_source
                        , stream_id
                        , platform
                        , event_dimensions
                        , ecommerce
                        , items)) event_data
        from `adh-demo-data-review.analytics_213025502.events_*` events
        where {% incrementcondition %} timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+'))) {%  endincrementcondition %}
          -- and timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+'))) >= ((TIMESTAMP_ADD(TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY), INTERVAL -29 DAY)))
          -- and  timestamp(PARSE_DATE('%Y%m%d', REGEXP_EXTRACT(_TABLE_SUFFIX,r'[0-9]+'))) <= ((TIMESTAMP_ADD(TIMESTAMP_ADD(TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY), INTERVAL -29 DAY), INTERVAL 30 DAY)))
        group by 1,2,3,4,5
  ),

-- Session-Level Facts, session start, end, duration
session_facts as (
  select sl.sl_key
      ,  COUNT(ed.event_timestamp) session_event_count
      ,  SUM(case when ed.event_name = 'page_view' then 1 else 0 end) session_page_view_count
      ,  COALESCE(SUM((select value.int_value from UNNEST(ed.event_params) where key = "engaged_session_event")),0) engaged_events
      ,  case when (COALESCE(SUM((select value.int_value from UNNEST(ed.event_params) where key = "engaged_session_event")),0) = 0
               and COALESCE(SUM((select coalesce(cast(value.string_value as INT64),value.int_value) from UNNEST(ed.event_params) where key = "session_engaged"))) = 0)
              then false else true end as is_engaged_session
            , case when countif(event_name = 'first_visit') = 0 then false else true end as is_first_visit_session
            , MAX(TIMESTAMP_MICROS(ed.event_timestamp)) as session_end
            , MIN(TIMESTAMP_MICROS(ed.event_timestamp)) as session_start
            , (MAX(ed.event_timestamp) - MIN(ed.event_timestamp))/(60 * 1000 * 1000) AS session_length_minutes
  from session_list_with_event_history sl
    ,  unnest(event_data) ed
  group by 1
  ),

-- Retrieves the last non-direct medium, source, and campaign from the session's page_view and user_engagement events.
session_tags as (
  select sl.sl_key
      ,  first_value((select value.string_value from unnest(ed.event_params) where key = 'medium')) over (partition by sl.session_date, sl.ga_session_id, sl.user_pseudo_id order by ed.event_timestamp desc) medium
      ,  first_value((select value.string_value from unnest(ed.event_params) where key = 'source')) over (partition by sl.session_date, sl.ga_session_id, sl.user_pseudo_id order by ed.event_timestamp desc) source
      ,  first_value((select value.string_value from unnest(ed.event_params) where key = 'campaign')) over (partition by sl.session_date, sl.ga_session_id, sl.user_pseudo_id order by ed.event_timestamp desc) campaign
      ,  first_value((select value.string_value from unnest(ed.event_params) where key = 'page_referrer')) over (partition by sl.session_date, sl.ga_session_id, sl.user_pseudo_id order by ed.event_timestamp desc) page_referrer
  from session_list_with_event_history sl
    ,  unnest(event_data) ed
  where ed.event_name in ('page_view','user_engagement')
    and (select value.string_value from unnest(ed.event_params) where key = 'medium') is not null
  ),

-- Device Columns from 'Session Start' event.
device as (
  select sl.sl_key
      ,  ed.device.category device__category
      ,  ed.device.mobile_brand_name device__mobile_brand_name
      ,  ed.device.mobile_model_name device__mobile_model_name
      ,  ed.device.mobile_brand_name||' '||device.mobile_model_name device__mobile_device_info
      ,  ed.device.mobile_marketing_name device__mobile_marketing_name
      ,  ed.device.mobile_os_hardware_model device__mobile_os_hardware_model
      ,  ed.device.operating_system device__operating_system
      ,  ed.device.operating_system_version device__operating_system_version
      ,  ed.device.vendor_id device__vendor_id
      ,  ed.device.advertising_id device__advertising_id
      ,  ed.device.language device__language
      ,  ed.device.time_zone_offset_seconds device__time_zone_offset_seconds
      ,  ed.device.is_limited_ad_tracking device__is_limited_ad_tracking
      ,  ed.device.web_info.browser device__web_info_browser
      ,  ed.device.web_info.browser_version device__web_info_browser_version
      ,  ed.device.web_info.hostname device__web_info_hostname
      ,  case when ed.device.category = 'mobile' then true else false end as device__is_mobile
  from session_list_with_event_history sl
    ,  unnest(event_data) ed
  where ed.event_name = 'session_start'
  ),

-- GEO Columns from 'Session Start' event.
geo as (
  select sl.sl_key
      ,  ed.geo.continent geo__continent
      ,  ed.geo.country geo__country
      ,  ed.geo.city geo__city
      ,  ed.geo.metro geo__metro
      ,  ed.geo.sub_continent geo__sub_continent
      ,  ed.geo.region geo__region
  from session_list_with_event_history sl
    ,  unnest(event_data) ed
  where ed.event_name = 'session_start'
  )

-- Final Select Statement:
select sl.session_date session_date
    ,  sl.ga_session_id ga_session_id
    ,  sl.ga_session_number ga_session_number
    ,  sl.user_pseudo_id user_pseudo_id
    ,  sl.sl_key
    -- packing session-level data into structs by category
    ,  (SELECT AS STRUCT coalesce(sa.medium,'(none)') medium
                      ,  coalesce(sa.source,'(direct)') source
                      ,  coalesce(sa.campaign,'(direct)') campaign
                      ,  sa.page_referrer ) session_attribution
    ,  (SELECT AS STRUCT sf.session_event_count
                      ,  sf.engaged_events
                      ,  sf.session_page_view_count
                      ,  sf.is_engaged_session
                      ,  sf.is_first_visit_session
                      ,  sf.session_end
                      ,  sf.session_start
                      ,  sf.session_length_minutes) session_data
    ,  (SELECT AS STRUCT d.device__category
                      ,  d.device__mobile_brand_name
                      ,  d.device__mobile_model_name
                      ,  d.device__mobile_device_info
                      ,  d.device__mobile_marketing_name
                      ,  d.device__mobile_os_hardware_model
                      ,  d.device__operating_system
                      ,  d.device__operating_system_version
                      ,  d.device__vendor_id
                      ,  d.device__advertising_id
                      ,  d.device__language
                      ,  d.device__time_zone_offset_seconds
                      ,  d.device__is_limited_ad_tracking
                      ,  d.device__web_info_browser
                      ,  d.device__web_info_browser_version
                      ,  d.device__web_info_hostname
                      ,  d.device__is_mobile) device_data
    ,  (SELECT AS STRUCT g.geo__continent
                      ,  g.geo__country
                      ,  g.geo__city
                      ,  g.geo__metro
                      ,  g.geo__sub_continent
                      ,  g.geo__region) geo_data
    ,  lag(sf.session_start) over (partition by sl.user_pseudo_id order by sl.ga_session_number) user_previous_session_start
    ,  lag(sf.session_end) over (partition by sl.user_pseudo_id order by sl.ga_session_number) user_previous_session_end
    ,  sl.event_data event_data
from session_list_with_event_history sl
left join session_tags sa
  on  sl.sl_key = sa.sl_key
left join session_facts sf
  on  sl.sl_key = sf.sl_key
left join device d
  on  sl.sl_key = d.sl_key
left join geo g
  on  sl.sl_key = g.sl_key
   ;;
  }


## Parameters

  parameter: audience_selector {
    view_label: "Audience"
    description: "Use to set 'Audience Trait' field to dynamically choose a user cohort."
    type: string
    allowed_value: { value: "Device" }
    allowed_value: { value: "Operating System" }
    allowed_value: { value: "Browser" }
    allowed_value: { value: "Country" }
    allowed_value: { value: "Continent" }
    allowed_value: { value: "Metro" }
    allowed_value: { value: "Language" }
    allowed_value: { value: "Channel" }
    allowed_value: { value: "Medium" }
    allowed_value: { value: "Source" }
    allowed_value: { value: "Source Medium" }
    default_value: "Source"
  }

## Dimensions
  dimension: sl_key {
    type: string
    sql: ${TABLE}.sl_key ;;
    primary_key: yes
    hidden: yes
  }

  dimension_group: session {
    type: time
    sql: ${TABLE}.session_date ;;
  }

  dimension: ga_session_id {
    type: number
    sql: ${TABLE}.ga_session_id ;;
  }

  dimension: ga_session_number {
    type: number
    sql: ${TABLE}.ga_session_number ;;
  }

  dimension: ga_session_number_tier {
    view_label: "Audience"
    group_label: "User"
    label: "Session Number Tier"
    description: "Session Number dimension grouped in tiers between 1-100. See 'Session Number' for full description."
    type: tier
    tiers: [1,2,5,10,15,20,50,100]
    style: integer
    sql: ${ga_session_number} ;;
  }

  dimension: user_pseudo_id {
    type: string
    sql: ${TABLE}.user_pseudo_id ;;
  }

  dimension: user_previous_session_start {
    sql: ${TABLE}.user_previous_session_start ;;
  }

  dimension: user_previous_session_end {
    sql: ${TABLE}.user_previous_session_end ;;
  }

  dimension_group: since_previous_session {
    type: duration
    intervals: [second,hour,minute,day,week]
    sql_start: ${user_previous_session_end} ;;
    sql_end: ${session_data_session_start_raw} ;;
  }

  dimension: days_since_previous_session_tier {
    # view_label: "Audience"
    # group_label: "User"
    description: "Days since the previous session. 0 if user only has 1 session."
    type: tier
    style: integer
    tiers: [1,2,4,8,15,31,61,121,365]
    sql: ${days_since_previous_session};;
  }

  dimension: event_data {
    hidden: yes
    type: string
    sql: ${TABLE}.event_data ;;
    ## This is the parent array that contains the event_data struct elements. It is not directly useably as a dimension.
    ## It is necessary for proper unnesting in the model Join.
  }

  dimension: audience_trait {
    view_label: "Audience"
    group_label: "Audience Cohorts"
    description: "Dynamic cohort field based on value set in 'Audience Selector' filter."
    type: string
    sql: CASE
              WHEN {% parameter audience_selector %} = 'Channel' THEN ${session_attribution_channel}
              WHEN {% parameter audience_selector %} = 'Medium' THEN ${session_attribution_medium}
              WHEN {% parameter audience_selector %} = 'Source' THEN ${session_attribution_source}
              WHEN {% parameter audience_selector %} = 'Source Medium' THEN ${session_attribution_source_medium}
              WHEN {% parameter audience_selector %} = 'Device' THEN ${device_data_device_category}
              WHEN {% parameter audience_selector %} = 'Browser' THEN ${device_data_web_info_browser}
              WHEN {% parameter audience_selector %} = 'Metro' THEN ${geo_data_metro}
              WHEN {% parameter audience_selector %} = 'Country' THEN ${geo_data_country}
              WHEN {% parameter audience_selector %} = 'Continent' THEN ${geo_data_continent}
              WHEN {% parameter audience_selector %} = 'Language' THEN ${device_data_language}
              WHEN {% parameter audience_selector %} = 'Operating System' THEN ${device_data_operating_system}
        END;;
  }

  ## Session Data Dimensions
  dimension: session_data {
    type: string
    sql: ${TABLE}.session_data ;;
    hidden: yes
    ## This is the Parent Struct that contains the session_data elements. It is not directly useably as a dimension.
    ## It is referred to by its child dimensions in their sql definition.
  }

    dimension: session_data_session_event_count {
      type: number
      sql: ${session_data}.session_event_count ;;
      label: "Session Event Count"
    }

    dimension: session_data_engaged_events {
      type: number
      sql: ${session_data}.engaged_events ;;
      label: "Session Engaged Event Count"
    }

    dimension: session_data_page_view_count {
      type: number
      sql: ${session_data}.session_page_view_count ;;
      label: "Session Page View Count"
    }

    dimension: session_data_page_view_count_tier {

    }

    dimension: session_data_is_engaged_session {
      type: yesno
      sql: ${session_data}.is_engaged_session ;;
      label: "Is Engaged Session?"
    }

    dimension: session_data_is_first_visit_session {
      type: yesno
      sql: ${session_data}.is_first_visit_session ;;
      label: "Is First Visit Session?"
    }

    dimension_group: session_data_session_end {
      type: time
      sql: ${session_data}.session_end ;;
      timeframes: [raw,time,hour,hour_of_day,date,day_of_week,day_of_week_index,week,month,year]
      label: "Session End"
    }

    dimension_group: session_data_session_start {
      type: time
      sql: ${session_data}.session_start ;;
      timeframes: [raw,time,hour,hour_of_day,date,day_of_week,day_of_week_index,week,month,year]
      label: "Session Start"
    }

    dimension: session_data_session_duration {
      type: number
      sql: ((TIMESTAMP_DIFF(${session_data_session_end_raw}, ${session_data_session_start_raw}, second))/86400.0)  ;;
      value_format_name: hour_format
      label: "Session Duration"
    }

    dimension: session_data_session_duration_tier {
      label: "Session Duration Tiers"
      description: "The length (returned as a string) of a session measured in seconds and reported in second increments."
      type: tier
      sql: (${session_data_session_duration}*86400.0) ;;
      tiers: [10,30,60,120,180,240,300,600]
      style: integer
    }

    dimension: session_data_is_bounce {
      type: yesno
      sql: ${session_data_session_duration} = 0 AND ${session_data_engaged_events} = 0;;
      label: "Is Bounce?"
      description: "If Session Duration Minutes = 0 and there are no engaged events in the Session, then Bounce = True."
    }

  ## Session Attribution Dimensions
  dimension: session_attribution {
    type: string
    sql: ${TABLE}.session_attribution ;;
    hidden: yes
    ## This is the Parent Struct that contains the session_attribution elements. It is not directly useably as a dimension.
    ## It is referred to by its child dimensions in their sql definition.
  }

    dimension: session_attribution_page_referrer {
      group_label: "Attribution"
      label: "Page Referrer"
      type: string
      sql: ${session_attribution}.page_referrer ;;
    }

    dimension: session_attribution_campaign {
      group_label: "Attribution"
      label: "Campaign"
      type: string
      sql: ${session_attribution}.campaign ;;
    }

    dimension: session_attribution_source {
      group_label: "Attribution"
      label: "Source"
      type: string
      sql: ${session_attribution}.source ;;
    }

    dimension: session_attribution_medium {
      group_label: "Attribution"
      label: "Medium"
      type: string
      sql: ${session_attribution}.medium ;;
    }

    dimension: session_attribution_source_medium {
      group_label: "Attribution"
      label: "Source Medium"
      type: string
      sql: ${session_attribution}.source||' '||${session_attribution}.medium ;;
    }

    dimension: session_attribution_channel {
      group_label: "Attribution"
      label: "Channel"
      description: "Default Channel Grouping as defined in https://support.google.com/analytics/answer/9756891?hl=en"
      sql: case when ${session_attribution_source} = '(direct)'
                 and (${session_attribution_medium} = '(none)' or ${session_attribution_medium} = '(not set)')
                  then 'Direct'
                when ${session_attribution_medium} = 'organic'
                  then 'Organic Search'
                when REGEXP_CONTAINS(${session_attribution_source}, r"^(facebook|instagram|pinterest|reddit|twitter|linkedin)") = true
                 and REGEXP_CONTAINS(${session_attribution_medium}, r"^(cpc|ppc|paid)") = true
                  then 'Paid Social'
                when REGEXP_CONTAINS(${session_attribution_source}, r"^(facebook|instagram|pinterest|reddit|twitter|linkedin)") = true
                  or REGEXP_CONTAINS(${session_attribution_medium}, r"^(social|social-network|social-media|sm|social network|social media)") = true
                  then 'Organic Social'
                when REGEXP_CONTAINS(${session_attribution_medium}, r"email|e-mail|e_mail|e mail") = true
                  or REGEXP_CONTAINS(${session_attribution_source}, r"email|e-mail|e_mail|e mail") = true
                  then 'Email'
                when REGEXP_CONTAINS(${session_attribution_medium}, r"affiliate|affiliates") = true
                  then 'Affiliates'
                when ${session_attribution_medium} = 'referral'
                  then 'Referral'
                when REGEXP_CONTAINS(${session_attribution_medium}, r"^(cpc|ppc|paidsearch)$")
                  then 'Paid Search'
                when REGEXP_CONTAINS(${session_attribution_medium}, r"^(display|cpm|banner)$")
                  then 'Display'
                when REGEXP_CONTAINS(${session_attribution_medium}, r"^(cpv|cpa|cpp|content-text)$")
                  then 'Other Advertising'
                else '(Other)' end ;;
    }

  ## Session Device Data Dimensions
  dimension: device_data {
    type: string
    sql: ${TABLE}.device_data ;;
    hidden: yes
    ## This is the Parent Struct that contains the device_data elements. It is not directly useably as a dimension.
    ## It is referred to by its child dimensions in their sql definition.
  }

    dimension: device_data_device_category {
      group_label: "Device"
      label: "Device Category"
      type: string
      sql: ${device_data}.device__category ;;
    }

    dimension: device_data_mobile_brand_name {
      group_label: "Device"
      label: "Mobile Brand Name"
      type: string
      sql: ${device_data}.device__mobile_brand_name ;;
    }

    dimension: device_data_mobile_model_name {
      group_label: "Device"
      label: "Mobile Model Name"
      type: string
      sql: ${device_data}.device__mobile_model_name ;;
    }

    dimension: device_data_mobile_device_info {
      group_label: "Device"
      label: "Mobile Device Info"
      type: string
      sql: ${device_data}.device__mobile_device_info ;;
    }

    dimension: device_data_mobile_marketing_name {
      group_label: "Device"
      label: "Mobile Marketing Name"
      type: string
      sql: ${device_data}.device__mobile_marketing_name ;;
    }

    dimension: device_data_mobile_os_hardware_model {
      group_label: "Device"
      label: "Mobile OS Hardware Model"
      type: string
      sql: ${device_data}.device__mobile_os_hardware_model ;;
    }

    dimension: device_data_operating_system {
      group_label: "Device"
      label: "Operating System"
      type: string
      sql: ${device_data}.device__operating_system ;;
    }

    dimension: device_data_operating_system_version {
      group_label: "Device"
      label: "Operating System Version"
      type: string
      sql: ${device_data}.device__operating_system_version ;;
    }

    dimension: device_data_vendor_id {
      group_label: "Device"
      label: "Vendor ID"
      type: string
      sql: ${device_data}.device__vendor_id ;;
    }

    dimension: device_data_advertising_id {
      group_label: "Device"
      label: "Advertising ID"
      type: string
      sql: ${device_data}.device__advertising_id ;;
    }

    dimension: device_data_language {
      group_label: "Device"
      label: "Language"
      type: string
      sql: ${device_data}.device__language ;;
    }

    dimension: device_data_time_zone_offset_seconds {
      group_label: "Device"
      label: "Time Zone Offset Seconds"
      type: number
      sql: ${device_data}.device__time_zone_offset_seconds ;;
    }

    dimension: device_data_is_limited_ad_tracking {
      group_label: "Device"
      label: "Is Limited Ad Tracking?"
      type: string
      sql: ${device_data}.device__is_limited_ad_tracking ;;
    }

    dimension: device_data_web_info_browser {
      group_label: "Device"
      label: "Browser"
      type: string
      sql: ${device_data}.device__web_info_browser ;;
    }

    dimension: device_data_web_info_browser_version {
      group_label: "Device"
      label: "Browser Version"
      type: string
      sql: ${device_data}.device__web_info_browser_version ;;
    }

    dimension: device_data_web_info_hostname {
      group_label: "Device"
      label: "Hostname"
      type: string
      sql: ${device_data}.device__web_info_hostname ;;
    }

  ## Session Geo Data Dimensions
  dimension: geo_data {
    type: string
    sql: ${TABLE}.geo_data ;;
    hidden: yes
    ## This is the Parent Struct that contains the geo_data elements. It is not directly useably as a dimension.
    ## It is referred to by its child dimensions in their sql definition.
  }

    dimension: geo_data_continent {
      group_label: "Geo"
      label: "Continent"
      type: string
      sql: ${geo_data}.geo__continent ;;
    }

    dimension: geo_data_country {
      group_label: "Geo"
      label: "Country"
      type: string
      sql: ${geo_data}.geo__country ;;
      map_layer_name: countries
    }

    dimension: geo_data_city {
      group_label: "Geo"
      label: "City"
      type: string
      sql: ${geo_data}.geo__city ;;
    }

    dimension: geo_data_metro {
      group_label: "Geo"
      label: "Metro"
      type: string
      sql: ${geo_data}.geo__metro ;;
    }

    dimension: geo_data_sub_continent {
      group_label: "Geo"
      label: "Sub-Continent"
      type: string
      sql: ${geo_data}.geo__sub_continent ;;
    }

    dimension: geo_data_region {
      group_label: "Geo"
      label: "Region"
      type: string
      sql: ${geo_data}.geo__region ;;
      map_layer_name: us_states
    }


## Measures

  measure: total_sessions {
    view_label: "Metrics"
    group_label: "Session"
    type: count_distinct
    sql: ${sl_key} ;;
    value_format_name: formatted_number
  }

  measure: total_first_visit_sessions {
    view_label: "Metrics"
    group_label: "Session"
    type: count_distinct
    sql: ${sl_key} ;;
    filters: [session_data_is_first_visit_session: "yes"]
    value_format_name: formatted_number
  }

  measure: total_first_visit_sessions_percentage {
    view_label: "Metrics"
    group_label: "Session"
    type: number
    sql: ${total_first_visit_sessions}/nullif(${total_sessions},0) ;;
    value_format_name: percent_2
  }

  measure: total_engaged_sessions {
    view_label: "Metrics"
    group_label: "Session"
    type: count_distinct
    sql: ${sl_key} ;;
    filters: [session_data_is_engaged_session: "yes"]
    value_format_name: formatted_number
  }

  measure: total_engaged_sessions_percentage {
    view_label: "Metrics"
    group_label: "Session"
    type: number
    sql: ${total_engaged_sessions}/nullif(${total_sessions},0) ;;
    value_format_name: percent_2
  }

  measure: average_page_views_per_session {
    view_label: "Metrics"
    group_label: "Session"
    label: "Avg. Page Views per Session"
    type: average
    sql: ${session_data_page_view_count} ;;
    value_format_name: decimal_2
  }

  measure: total_bounced_sessions {
    view_label: "Metrics"
    group_label: "Session"
    type: count_distinct
    sql: ${sl_key} ;;
    filters: [session_data_is_bounce: "yes"]
    value_format_name: formatted_number
  }

  measure: total_bounced_sessions_percentage {
    view_label: "Metrics"
    group_label: "Session"
    type: number
    sql: ${total_bounced_sessions}/nullif(${total_sessions},0) ;;
    value_format_name: percent_2
  }

  measure: average_session_duration {
    view_label: "Metrics"
    group_label: "Session"
    type: average
    sql: ${session_data_session_duration} ;;
    value_format_name: hour_format
    label: "Average Session Duration (HH:MM:SS)"
  }

  measure: total_users {
    view_label: "Metrics"
    group_label: "Session"
    label: "Total Users"
    description: "Distinct/Unique count of User Pseudo ID"
    type: count_distinct
    sql: ${user_pseudo_id} ;;
    value_format_name: formatted_number
  }

  measure: total_new_users {
    view_label: "Metrics"
    group_label: "Session"
    label: "Total New Users"
    description: "Distinct/Unique count of User Pseudo ID where GA Session Number = 1"
    type: count_distinct
    sql: ${user_pseudo_id} ;;
    filters: [session_data_is_first_visit_session: "yes"]
    value_format_name: formatted_number
  }

  measure: total_returning_users {
    view_label: "Metrics"
    group_label: "Session"
    label: "Total Returning Users"
    description: "Distinct/Unique count of User Pseudo ID where GA Session Number > 1"
    type: count_distinct
    sql: ${user_pseudo_id} ;;
    filters: [session_data_is_first_visit_session: "no"]
    value_format_name: formatted_number
  }

  measure: percentage_new_users {
    view_label: "Metrics"
    group_label: "Session"
    label: "Total New Users - Percentage"
    type: number
    sql: ${total_new_users}/nullif(${total_users},0) ;;
    value_format_name: percent_2
  }

  measure: percentage_returning_users {
    view_label: "Metrics"
    group_label: "Session"
    label: "Total Returning Users - Percentage"
    type: number
    sql: ${total_returning_users}/nullif(${total_users},0) ;;
    value_format_name: percent_2
  }

}