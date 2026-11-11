{{
    config(
        file_format='iceberg',
        materialized='incremental',
        incremental_strategy='insert_overwrite',
        unique_key='dt, site_id, visitor_id, visitor_subsession_index',
        partition_by='dt',
        clustered_by='visitor_id',
        buckets = '8',
        on_schema_change='append_new_columns',
        tags=["daily", "dt_partition"]
    )
}}

{{
    config.set('options',
        {
            '"format-version"': 2,
            '"write.format.default"': "parquet",
            '"write.metadata.delete-after-commit.enabled"': "true",
            '"write.distribution-mode"': "hash",
            '"write.parquet.row-group-size-bytes"':'33554432',
            '"write.target-file-size-bytes"':'536870912',
            '"write.metadata.previous-versions-max"': 20
        }
    )
}}



with select_field_ff as (
    select
        date(ts_est) as dt,
        si as visitor_id,
        rq as request_correlation_id,
        fmnm,
        fctx


    from {{ ref('missing_events') }}
    where et = 'SELECT.FIELD'
    group by 1,2,3,4,5
),

browser_autofill_field_ff as (
    select
        date(ts_est) as dt,
        si as visitor_id,
        rq as request_correlation_id

    from {{ ref('missing_events') }}
    where et = 'BROWSER_AUTOFILL.FIELD'
    group by 1,2,3
),

addr_payment_field_ff as (
    select
        date(ts_est) as dt,
        si as visitor_id,
        rq as request_correlation_id

    from {{ ref('missing_events') }}
    where et in ('SELECT.ADDRESS', 'PAYPAL.PAYMENT')
    group by 1,2,3
),

pdims as (
  select
  prdct_id,
  bgn_ts,
  end_ts,
  department_scd as byr_dept_nm,
  department_scd = 'JER' as is_jer_pid,
  lower(subcategory_scd) like 'apparel%' and regexp_like(lower(style_scd), '.*blank .*|.*custom .*') as is_mto_pid
  from {{ ref('product_scd') }}
),

forex_rates as (
    select *
    from (
        select
            distinct
            target_crncy_cd as targetcurrencycode,
            base_crncy_cd as basecurrencycode,
            forex_rt_rt as rate,
            forex_rt_effective_ts as start_utc,
            coalesce(
                lead(forex_rt_effective_ts, 1) OVER (
                    PARTITION BY base_crncy_cd, target_crncy_cd
                    ORDER BY forex_rt_effective_ts ASC
                ),
                to_timestamp('2100-01-01')
            ) as end_utc
        from exp_prod.forex_rate_lookup
        where forex_rt_type_id = 1
            and target_crncy_cd = 'USD'
    ) t
    where start_utc != end_utc and end_utc >= timestamp('2020-01-01')
),

-- Updated wts CTE to include forex conversion and admin_crncy_cd
wts as (
    select
        w.altorderid as order_ref_num,
        (CASE WHEN (w.partnersiteid < 500000) THEN (w.partnersiteid + 500000) ELSE w.partnersiteid END) site_id,
        w.sales_cntry_cd,
        w.ship_city,
        w.ship_state,
        w.ship_cntry_cd,
        w.ship_zip_cd,
        w.admin_crncy_cd,
        min(w.client_id) as internal_surrogate_key,
        sum(w.ordered_item_net_demand * coalesce(fx.rate, 1.0)) as net_demand_usd,  --  Convert to USD
        sum(w.contribution_margin * coalesce(fx.rate, 1.0)) as contribution_margin_usd,  -- Convert to USD
        sum(w.contribution_margin_less_fixed_costs * coalesce(fx.rate, 1.0)) as contribution_margin_less_fixed_costs_usd,  -- Convert to USD
        sum(w.ordered_item_quantity) as ordered_quantity,
        sum(w.ordered_item_net_demand) as net_demand,
        sum(w.contribution_margin) as contribution_margin,
        sum(w.contribution_margin_less_fixed_costs) as contribution_margin_less_fixed_costs,
        sum(w.outbound_freight * coalesce(fx.rate, 1.0)) as outbound_freight_usd

    from {{ source('exp_prod', 'weekly_trading_legacy') }} w
    -- Join with forex rates based on order ts and currency
    left join forex_rates fx
        on w.admin_crncy_cd = fx.basecurrencycode
        and w.order_ts_utc >= fx.start_utc
        and w.order_ts_utc < fx.end_utc
    where w.order_dt_eastern >= '{{ var("START_DATE") }}'
        AND w.order_dt_eastern <= '{{ var("END_DATE") }}'
    group by 1,2,3,4,5,6,7,8

),

page_views AS (
    SELECT
        *,
        cast(case when site_id < 510005 then 0
            when site_id < 510006 then 1 +  if( substring(visitor_id, 1, 1) > '7',  1 , 0)
            when site_id < 512730 then 3
            when site_id < 512909 then 4
            when site_id < 514699 then 5
            else 6 end as string
        ) as site_bin, -- approximately even-sized buckets
        int(sum(case when page_type = 'THKU' and order_ref_num is not null then 1 else 0 end)
                over (partition by dt, site_id, visitor_id
                order by timestamp_est, visit_num, page_num)
                - int(page_type = 'THKU' and order_ref_num is not null))
                as visitor_subsession_index,

        timestamp_millis(timestamp) as ts_utc,

        concat(
            -- coalesce(slice(array_compact(array_distinct(flatten(transform(user_query_filters, x -> split(lower(x), ','))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(link_engagements, x -> lower(to_json(struct(x.lctx, x.lid)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(button_engagements, x -> lower(to_json(struct(x.bctx, x.bid)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(from_json(accordion_engagements, 'array<struct<aid:string,act:string>>'), x -> lower(to_json(struct(x.act, x.aid)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(item_list_click, x -> lower(to_json(struct(x.listctx, x.listid, x.listType)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(checkbox_click, x -> lower(to_json(struct(x.elctx, x.elid)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(select_field_property, x -> lower(to_json(struct(x.fctx, x.fmnm)))))),1,20), array()),
            coalesce(slice(array_compact(array_distinct(transform(open_list_engagements, x -> lower(to_json(struct(x.listCtx, x.listId)))))),1,20), array())
        ) as engagements,

        page_type rlike 'LP|DDP' and not page_type in ('XLP', 'HLP', 'GCLP', 'SLP') as is_grid_page,
        page_type in ('PDP', 'FPP') as is_product_page,
        page_type in ('PDP') as is_pdp,
        page_type in ('FPP') as is_fpp,
        page_type in ('SRP') as is_search_page, --- update from AVEXP-1274 to drop SFLP
        page_type rlike 'LP|DDP' and not page_type in ('XLP', 'HLP', 'GCLP', 'SLP') and department_name = 'Jerseys' as is_jer_grid,

        array_contains(event_list_arr, '2') as has_atc,
        page_type = 'CART' and 	cardinality(array_distinct(array_compact(transform(
            cart_summary.final_cart_content, f -> f.product_id)))) > 0 as has_nonempty_cart,
        array_contains(event_list_arr, '107') as has_filter_clicks,
        array_contains(event_list_arr, '510') as has_leftnav_clicks,
        array_contains(event_list_arr, '121') as has_topnav_clicks,

        click_position >= 0 as is_typeahead,
        -- array_compact(array_distinct(concat(transform(user_query_filters, x -> split(x, ','))))) as user_query_filters_flattened,
        CAST(REGEXP_EXTRACT((LOWER(page_url)), '_ref.*lp.*-grid.*po-(\\d+)') AS INT) as grid_position_clicked,

        cart_summary.final_cart_net_total as final_cart_net_total,
        cart_summary.final_cart_gross_total as final_cart_gross_total,
        cart_summary.final_cart_unit_total as final_cart_unit_total,
		cardinality(array_distinct(array_compact(transform(
            cart_summary.final_cart_content, f -> f.product_id)))) as final_cart_pid_count,

        case when page_type = 'CHKT' then cart_summary.final_cart_net_total end as final_cart_net_total_on_chkt,
        case when page_type = 'CHKT' then cart_summary.final_cart_gross_total end as final_cart_gross_total_on_chkt,
        case when page_type = 'CHKT' then cart_summary.final_cart_unit_total end as final_cart_unit_total_on_chkt,

        concat(fd.fmnm, fd.fctx) as select_field_combo,
        baf.request_correlation_id is not null as has_browser_autofill_field,
        adp.request_correlation_id is not null as has_addr_payment_field,
        item_list_click is not null as has_item_list_click,
        checkbox_click is not null as has_checkbox_click,
        link_engagements is not null as has_link_engagement,
        pd.byr_dept_nm,
        pd.is_jer_pid,
        pd.is_mto_pid
        -- pv.geo_zip,
        -- pv.geo_city,
        -- pv.geo_country_code,
        -- pv.geo_region

    FROM
        {{ ref('filtered_page_view_ice') }} pv
    left join pdims pd
         on (pv.product_id = pd.prdct_id and timestamp_millis(pv.timestamp) >= pd.bgn_ts and timestamp_millis(pv.timestamp) < pd.end_ts)
    left join select_field_ff fd
        using (dt, visitor_id, request_correlation_id)
    left join browser_autofill_field_ff baf
        using (dt, visitor_id, request_correlation_id)
    left join addr_payment_field_ff adp
        using (dt, visitor_id, request_correlation_id)
        
    where (page_num < 1000 or (page_type = 'THKU' and order_ref_num is not null))
),

dv as (
    select
        dt,
        visitor_id,
        site_id,
        
        visitor_subsession_index,
        min_by(geo_city, timestamp_est) as geo_city,
        min_by(geo_country_code, timestamp_est) as geo_country_code,
        min_by(geo_zip, timestamp_est) as geo_zip,
        min_by(geo_region, timestamp_est) as geo_region,
        min_by(device, timestamp_est) as device,
        max(biz_segment) as biz_segment,
        max(hostname) as hostname,

        unix_millis(min(ts_utc)) as min_ts_millis_utc,
        unix_millis(max(ts_utc)) as max_ts_millis_utc,


        max(order_ref_num) as order_ref_num,
        max(user_account_id) as user_account_id,
        max(struct(fankey is not null as f1, timestamp_est as f2, fankey as f3)).f3 as fankey_iris,
        min(visit_num) as visit_num,
        max(visit_num) as visit_num_max,
        min_by(user_account_state, timestamp_est) as first_user_account_state,
        max(user_account_state in ('loggedin')) as is_loggedin,
        max((user_account_state in ('loggedin', 'recognized') and (dt >= '2024-09-03' or user_account_id is not null)) or (fankey is not null)) as is_recognized,
        max(page_num) as page_num_max,
        int((max(timestamp_est) - min(timestamp_est)) / 1000) as time_on_site_secs,

        min_by(channel_session_code, timestamp_est) as channel_session_code,
        min_by(channel_30d_code, timestamp_est) as channel_30d_code,
        min_by(utm_campaign, timestamp_est) as utm_campaign,
	    min_by(source_query_param, timestamp_est) as source_query_param,
        int(count(distinct internal_search_term)) as search_term_count,

        max_by(final_cart_pid_count, timestamp_est) as final_cart_pid_count,
        max_by(final_cart_unit_total, timestamp_est) as final_cart_unit_total,
        max_by(final_cart_net_total, timestamp_est) as final_cart_net_total,
        max_by(final_cart_gross_total, timestamp_est) as final_cart_gross_total,

        max_by(final_cart_net_total_on_chkt, timestamp_est) as final_cart_net_total_on_chkt,
        max_by(final_cart_gross_total_on_chkt, timestamp_est) as final_cart_gross_total_on_chkt,
        max_by(final_cart_unit_total_on_chkt, timestamp_est) as final_cart_unit_total_on_chkt,

        --- for cart_activity calcs 
        min(case when has_topnav_clicks then timestamp_est end) as first_topnav_clicks,
        min(case when has_leftnav_clicks then timestamp_est end) as first_leftnav_clicks,
        min(case when has_filter_clicks then timestamp_est end) as first_filter_clicks,
        min(case when is_jer_grid then timestamp_est end) as first_jer_grid_views,
        min(case when is_jer_pid then timestamp_est end) as first_jer_pid_views,
        min(case when is_mto_pid then timestamp_est end) as first_mto_pid_views,
        min(case when has_atc then timestamp_est end) as first_cart_activity,
        --- for nav to cart 
        max(case when 
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            then timestamp_est end
        ) as first_global_topnav_clicks,
        max(case when 
            array_contains(event_list_arr, '121') 
            AND exists(engagements, x -> x rlike 'topnav-group-o-')
            then timestamp_est end
        ) as first_global_topnav_team_clicks,
        max(case when 
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND NOT exists(engagements, x -> x rlike 'topnav-group-o-')
            then timestamp_est end
        ) as first_global_topnav_non_team_clicks,
        min(case when
            array_contains(event_list_arr, '121')
            AND array_contains(event_list_arr, '230')
            AND exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
            then timestamp_est end
        ) as first_team_topnav_clicks,

        count(distinct session_id) as session_count,
        count(distinct case when page_type = 'SRP' then session_id end) as srp_session_count,
        count(distinct case when page_type = 'PDP' then session_id end) as pdp_session_count,
        count(distinct case when page_type = 'FPP' then session_id end) as fpp_session_count,

        max(has_atc) AS has_atc,
        array_join(transform(array_sort(COLLECT_LIST(struct(
            timestamp_est,
            CASE
            WHEN is_search_page
            THEN 'S'
            WHEN page_type = 'HP'
            THEN 'H'
            WHEN is_grid_page
            THEN 'G'
            WHEN page_type = 'PDP'
            THEN 'P'
            WHEN page_type = 'FPP'
            THEN 'F'
            WHEN page_type = 'CART'
            THEN '1'
            WHEN page_type = 'SHPG'
            THEN '2'
            WHEN page_type = 'CHKT'
            THEN '3'
            WHEN page_type = 'THKU'
            THEN '4'
            ELSE '_'
            END ||
            case when is_typeahead then 'T' ELSE '' END ||
            case when has_atc or has_nonempty_cart then 'A' ELSE '' END
        as pt
        ))), x -> x.pt), '') AS pages_grouped,
        max(is_product_page) as has_product_page_view,
        max(final_cart_pid_count) > 0 as nonemptycart_visitor,
        int(count_if(is_product_page)) as product_view_count,
        int(count_if(is_pdp)) as pdp_view_count,
        int(count_if(is_fpp)) as fpp_view_count,
        int(count_if(is_jer_pid)) as jer_product_view_count,
        int(count_if(is_mto_pid)) as mto_product_view_count,
        int(count(distinct product_id)) as unique_product_view_count,
        int(count_if(is_search_page)) as search_page_view_count,
        int(count_if(is_grid_page)) as grid_page_view_count,
        any_value(run_ts) as src_ts,
        case when '{{ var("SCHEMA_NAME") }}' = 'exp_staging' then array_distinct(flatten(array_agg(engagements))) end as engagements_debug,

        -- LEADING INDICATOR FIELDS
        -- first_user_account_state,
        -- is_loggedin,
        -- is_recognized, ---- already exists 
        -- channel, ---- already exists 
        -- device,
        -- biz_segment,
        -- hostname,
        -- is_bounce, ---- is_single_page_visitor in the next CTE
        -- site_id, ---- already exists 
        min_by(team_name, timestamp_est) as entry_team,
        min_by(league_name, timestamp_est) as entry_league,
        min_by(department_name, timestamp_est) as entry_dept,
        min_by(team_name, timestamp_est) is not null as has_entry_team,
        min_by(league_name, timestamp_est) is not null as has_entry_league,
        min_by(department_name, timestamp_est) is not null as has_entry_dept,
        -- utm_campaign, ---- already exists 
        min_by(promo_type, timestamp_est) as promo_type,
        min_by(page_type, timestamp_est) as entry_page_type,
        array_join(
          transform(
            array_sort(collect_list(struct(timestamp_est, page_type))),
            x -> x.page_type
          ),
          ', '
        ) AS all_page_types,
        max_by(page_type, timestamp_est) as exit_page_type,
        max(fancash_available) as fc_available,
        -- new_vs_return, --- derive in the next CTE 
        -- order_ref_num, ---- already exists 
        -- has_atc, --- already exists 
        max(order_ref_num is not null) as converted,
        -- has_cart_activity, --- in the next CTE
        -- has_filter_to_cart_activity, --- in the next CTE
        -- has_topnav_to_cart_activity, --- in the next CTE
        -- has_srp_to_pdp, --- in the next CTE
        -- has_jersey_product_page_to_cart_activity, -- in the next CTE
        -- has_mto_product_page_to_cart_activity, -- in the next CTE
        -- has_jersey_grid_page_to_cart_activity, -- in the next CTE
        -- max(null /* todo: tracking not implemented */) as has_mto_grid_page_to_cart_activity, 
        -- has_search_to_cart_activity, -- in the next CTE
        -- has_pdp_to_cart_activity, -- in the next CTE
        -- has_fpp_to_cart_activity, -- in the next CTE
        -- has_leftnav_engagement_to_cart_activity, -- in the next CTE
        -- has_typeahead_cart_activity -- in the next CTE

        -- HP
        max(exists(engagements, x -> x rlike 'topnav-group-o-') and page_type = 'HP') as has_league_team_topnav_on_hp,
        max(exists(engagements, x -> x rlike 'topnav-group-ga-') and page_type = 'HP') as has_gender_age_topnav_on_hp,
        max(exists(engagements, x -> x rlike 'topnav-(group-d-|mnLnk-|o-)') and page_type = 'HP') as has_department_topnav_on_hp,
        max(array_contains(event_list_arr, '1') and page_type = 'HP') as has_search_on_hp,
        max(exists(engagements, x -> x rlike 'cart-icon') and page_type = 'HP') as has_cart_icon_on_hp,
        max(exists(engagements, x -> x rlike 'site-logo') and page_type = 'HP') as has_site_logo_on_hp,
        max(array_contains(event_list_arr, '121') and page_type = 'HP') as has_topnav_on_hp,
        max(exists(engagements, x -> x rlike 'team-widget') and page_type = 'HP') as has_team_widget_on_hp,
        max(regexp_like(lower(coalesce(page_url, '')), 'pt-(home|hp)')  and lower(coalesce(page_url, '')) like '%a_spot%') as has_a_spot_on_hp,
        max(regexp_like(lower(coalesce(page_url, '')), 'pt-(home|hp)')  and not lower(coalesce(page_url, '')) like '%a_spot%') as has_other_content_on_hp,

        -- Global NAV
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
        ) as has_global_topnav,
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND is_grid_page
        ) as has_global_topnav_on_grid,
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND NOT is_grid_page
        ) as has_global_topnav_on_non_grid,
        max(
            array_contains(event_list_arr, '121') 
            AND exists(engagements, x -> x rlike 'topnav-group-o-')
        ) as has_global_topnav_team,
        max(
            array_contains(event_list_arr, '121') 
            AND exists(engagements, x -> x rlike 'topnav-group-o-')
            AND is_grid_page
        ) as has_global_topnav_team_on_grid,
        max(
            array_contains(event_list_arr, '121') 
            AND exists(engagements, x -> x rlike 'topnav-group-o-')
            AND NOT is_grid_page
        ) as has_global_topnav_team_on_non_grid,
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND NOT exists(engagements, x -> x rlike 'topnav-group-o-')
        ) as has_global_topnav_non_team,
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND NOT exists(engagements, x -> x rlike 'topnav-group-o-')
            AND is_grid_page
        ) as has_global_topnav_non_team_on_grid,
        max(
            array_contains(event_list_arr, '121')
            AND (
              NOT array_contains(event_list_arr, '230')
              OR (
                  array_contains(event_list_arr, '230')
                  AND NOT exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')
                  )
              )
            AND NOT exists(engagements, x -> x rlike 'topnav-group-o-')
            AND NOT is_grid_page
        ) as has_global_topnav_non_team_on_non_grid,
        max(array_contains(event_list_arr, '121') AND array_contains(event_list_arr, '230') AND exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)')) as has_team_topnav,
        max(array_contains(event_list_arr, '121') AND array_contains(event_list_arr, '230') AND exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)') AND is_grid_page) as has_team_topnav_on_grid,
        max(array_contains(event_list_arr, '121') AND array_contains(event_list_arr, '230') AND exists(engagements, x -> x rlike 'contextual-topnav|topnav-group-(ga|d|os)') AND NOT is_grid_page) as has_team_topnav_on_non_grid,

        -- GRID: is_grid_page defined from previous CTE
        -- max(null /* todo: tracking not implemented */) as has_product_layout_grid_hit,
        -- max(null /* todo: tracking not implemented */) as has_content_layout_grid_hit,
        -- max(null /* todo: tracking not implemented */) as has_product_grid_engagement,
        max(exists(engagements, x -> x rlike 'topnav-group-o-') and is_grid_page) as has_league_team_topnav_on_grid,
        max(exists(engagements, x -> x rlike 'topnav-group-ga-') and is_grid_page) as has_gender_age_topnav_on_grid,
        max(exists(engagements, x -> x rlike 'topnav-(group-d-|mnLnk-|o-)') and is_grid_page) as has_department_topnav_on_grid,
        max(array_contains(event_list_arr, '1') and is_grid_page) as has_search_on_grid,
        max(exists(engagements, x -> x rlike 'cart-icon') and is_grid_page) as has_cart_icon_on_grid,
        max(exists(engagements, x -> x rlike 'team-widget') and is_grid_page) as has_team_widget_on_grid,
        max(array_contains(event_list_arr, '121') and is_grid_page) as has_topnav_on_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-(leagues|teams)') and is_grid_page) as has_league_team_sidenav_on_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-gender-age') and is_grid_page) as has_gender_age_sidenav_on_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-departments') and is_grid_page) as has_department_sidenav_on_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*' AND NOT (x rlike 'side-nav.*-(leagues|teams|gender-age|departments)')) AND is_grid_page) as has_other_sidenav_on_grid,
        max(array_contains(event_list_arr, '105') and is_grid_page) as has_pills_on_grid,
        max(exists(engagements, x -> x rlike 'static-sort-dropdown|page-|pagination') and is_grid_page) as has_pagination_on_grid, -- check if simplified logic works 
        max(exists(engagements, x -> x rlike 'top-breadcrumbs') and is_grid_page) as has_breadcrumbs_on_grid,
        max(exists(engagements, x -> x rlike 'site-logo') and is_grid_page) as has_site_logo_on_grid,
        max(search_result_count > 5000 and is_grid_page) as has_over_5000_products_on_grid,
        max(search_result_count > 1000 and search_result_count <= 5000 and is_grid_page) as has_between_1001_5000_products_on_grid,
        max(search_result_count > 500 and search_result_count <= 1000 and is_grid_page) as has_between_501_1000_products_on_grid,
        max(search_result_count > 256 and search_result_count <= 500 and is_grid_page) as has_between_257_500_products_on_grid,
        max(search_result_count > 72 and search_result_count <= 256 and is_grid_page) as has_between_73_256_products_on_grid,
        max(search_result_count <= 72 and is_grid_page) as has_under_72_products_on_grid,

        -- SEARCH 
        max(search_result_count > 1000 and page_type = 'SRP') as has_over_1000_products_on_srp,
        max(search_result_count > 500 and search_result_count <= 1000 and page_type = 'SRP') as has_between_501_1000_products_on_srp,
        max(search_result_count > 200 and search_result_count <= 500 and page_type = 'SRP') as has_between_201_500_products_on_srp,
        max(search_result_count <= 200 and page_type = 'SRP') as has_under_200_products_on_srp,
        max(array_contains(event_list_arr, '121') and page_type = 'SRP') as has_topnav_on_srp,
        max(array_contains(event_list_arr, '1') and page_type = 'SRP') as has_search_on_srp,
        max((ARRAY_CONTAINS(event_list_arr, '615') or ARRAY_CONTAINS(event_list_arr, '616')) and page_type = 'SRP') as has_typeahead_accepted_on_srp,  
        max((ARRAY_CONTAINS(event_list_arr, '615') or ARRAY_CONTAINS(event_list_arr, '616'))) as has_typeahead_accepted,
        max(array_contains(event_list_arr, '105') and page_type = 'SRP') as has_pills_on_srp,
        max(exists(engagements, x -> x rlike 'topnav-group-o-') and page_type = 'SRP') as has_league_team_topnav_on_srp,
        max(exists(engagements, x -> x rlike 'topnav-group-ga-') and page_type = 'SRP') as has_genderage_topnav_on_srp,
        max(exists(engagements, x -> x rlike 'topnav-(group-d-|mnLnk-|o-)') and page_type = 'SRP') as has_department_topnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*-gender-age') and page_type = 'SRP') as has_gender_age_sidenav_on_srp,
        max(exists(engagements, x -> x rlike 'team-widget') and page_type = 'SRP') as has_team_widget_on_srp, 
        max(exists(engagements, x -> x rlike 'side-nav.*') and page_type = 'SRP') as has_leftnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*-leagues') and page_type = 'SRP') as has_league_leftnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*-teams') and page_type = 'SRP') as has_team_leftnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*-departments' and NOT (x rlike 'side-nav.*-sale-items')) and page_type = 'SRP') as has_department_leftnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*-sale-items') and page_type = 'SRP') as has_price_leftnav_on_srp,
        max(exists(engagements, x -> x rlike 'side-nav.*' and NOT (x rlike 'side-nav.*-(leagues|teams|gender-age|departments|sale-items)')) and page_type = 'SRP') as has_other_leftnav_on_srp,
        filter(
          transform(
            array_sort(
              collect_list(
                struct(
                  timestamp_est,
                  case when array_contains(event_list_arr, '1') then page_type end as page_type
                )
              )
            ),
            x -> x.page_type
          ),
          x -> x is not null
        ) as origin_search_pages,
        -- need to evaluate if joining on internal_search_terms is efficient 
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. team is not null */) as team_intent_search,
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. player is not null */) as player_intent_search,
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. department is not null */) as department_intent_search,
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. token_count <= 3 */) as head__3_or_less_tokens,
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. token_count >=4 and <= 6 */) as torso_46_tokens,
        -- max(null /* todo: define tracking logic from: join to exp_prod.search_term_classification on internal_search_query. token_count >= 7 */) as tail_7_tokens,
        max(array_contains(event_list_arr, '276')) as typeahead_used,
        count(case when array_contains(event_list_arr, '1') then request_correlation_id end) as count_of_searches,
        
        -- PDP 
        count(case when upper(available_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)' and page_type = 'PDP' then request_correlation_id end) as core_size_pid_views_on_pdp,
        count(case when upper(unavailable_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)' and page_type = 'PDP' then request_correlation_id end) as core_size_oos_pid_views_on_pdp,
        max(cardinality(item_click)>=2 and page_type = 'PDP' ) as has_over_2_sizes_clicked_on_pdp,
        max(exists(engagements, x -> x rlike 'opening') and exists(engagements, x -> x rlike 'product-(details|description|shipping-details)') and page_type = 'PDP') as has_prod_accordion_on_pdp,
        sum(case when page_type = 'PDP' then cardinality(split(available_sizes, ',')) end) as available_sizes_count_on_pdp,
        sum(case when page_type = 'PDP' then cardinality(split(unavailable_sizes, ',')) end) as unavailable_sizes_count_on_pdp,
        max((array_contains(event_list_arr, '240') or array_contains(event_list_arr, '242') or exists(engagements, x -> x rlike 'rating-link-')) and page_type = 'PDP') as has_social_proof_engages_on_pdp,
        max(reviews.total_rating  >= 50 and page_type = 'PDP') as has_over_50_reviews_pid_views_on_pdp,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'product-details')) AS has_product_details,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'product-description')) AS has_product_description,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'ratings-summary')) AS has_product_ratings,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'product-shipping-details')) AS has_product_shipping_details,
        max(regexp_like(lower(value_props_shown), 'free_shipping|hyper_speed') and page_type = 'PDP') as has_pdp_value_props_shown,
        max(exists(engagements, x -> x rlike 'pdp-size-chart-link') and page_type = 'PDP') as has_size_chart_on_pdp,
        max(exists(engagements, x -> x rlike 'color-selector|\b(left|right|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and page_type = 'PDP') as has_image_color_interaction_on_pdp,
        max(array_contains(event_list_arr, '121') and page_type = 'PDP') as has_top_nav_on_pdp,
        -- pdp_atc, -- already exists as has_atc
        max(array_contains(event_list_arr, '1') and page_type = 'PDP') as has_search_on_pdp,
        max(regexp_like(page_url, 'p-PDP:m-RV')) as has_rv_carousel_on_pdp,
        max(regexp_like(page_url, 'p-PDP:m-YMAL')) as has_ymal_carousel_on_pdp,
        max(exists(engagements, x -> x rlike 'team-widget') and page_type = 'PDP') as has_team_widget_on_pdp, 
        max(array_contains(event_list_arr, '259') and page_type = 'PDP') as has_breadcrumbs_on_pdp,
        max(exists(engagements, x -> x rlike '\b(right|left|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and page_type = 'PDP') as has_image_clicked_on_pdp,

        -- CART 
        max(page_type = 'CART' and (array_contains(event_list_arr,'225') or array_contains(event_list_arr,'64') or array_contains(event_list_arr,'464') or array_contains(event_list_arr,'462') or array_contains(event_list_arr,'25'))) as has_value_clarity_on_cart,
        max(page_type = 'CART' and (array_contains(event_list_arr, '221') or array_contains(event_list_arr, '222'))) as has_quantity_interaction_on_cart,
        max(page_type = 'CART' and (array_contains(event_list_arr, '711') or array_contains(event_list_arr, '267')  or array_contains(event_list_arr, '645'))) as has_distraction_on_cart,
        max(page_type = 'CART' and (array_contains(event_list_arr,'259') or array_contains(event_list_arr,'121') or array_contains(event_list_arr,'1'))) as has_navigation_engagement_on_cart,
        count(case when page_type='CART' then request_correlation_id end) as cart_views,
        max(
            page_type = 'CART' and (
            array_contains(event_list_arr, '271')
            or array_contains(event_list_arr, '463')
            or array_contains(event_list_arr, '461')
            or array_contains(event_list_arr, '63')
        )
        ) as has_friction_on_cart,
        max(array_contains(event_list_arr, '121') and page_type = 'CART') as has_topnav_on_cart,
        max(array_contains(event_list_arr, '1') and page_type = 'CART') as has_search_on_cart,
        max(exists(engagements, x -> x rlike 'continue-shopping') and page_type = 'CART') as has_continue_shopping_on_cart,
        max(array_contains(event_list_arr, '25') and page_type = 'CART') as has_promo_qualifier_message_shown_on_cart,
        max(array_contains(event_list_arr, '215') and page_type = 'CART') as has_daily_deals_savings_on_cart,
        max(array_contains(event_list_arr, '216') and page_type = 'CART') as has_coupon_savings_on_cart,
        max(array_contains(event_list_arr, '217') and page_type = 'CART') as has_other_markdown_savings_on_cart,
        max(array_contains(event_list_arr, '221') and page_type = 'CART') as has_item_quantity_added_to_cart_on_cart,
        max(array_contains(event_list_arr, '222') and page_type = 'CART') as has_item_quantity_removed_from_cart_on_cart,
        max(array_contains(event_list_arr, '223') and page_type = 'CART') as has_item_size_updated_on_cart,
        max(array_contains(event_list_arr, '224') and page_type = 'CART') as has_cart_emptied_on_cart,
        max(array_contains(event_list_arr, '225') and page_type = 'CART') as has_total_savings_on_cart,
        max(array_contains(event_list_arr, '226') and page_type = 'CART') as has_markdown_savings_on_cart,
        max(array_contains(event_list_arr, '227') and page_type = 'CART') as has_shipping_savings_on_cart,
        max(array_contains(event_list_arr, '228') and page_type = 'CART') as has_discounts_on_cart,
        max(array_contains(event_list_arr, '271') and page_type = 'CART') as has_empty_carts_on_cart,
        max(array_contains(event_list_arr, '564') and page_type = 'CART') as has_digital_wallet_used_on_cart,
        max(array_contains(event_list_arr, '638') and page_type = 'CART') as has_remove_item_on_cart,
        max(array_contains(event_list_arr, '706') and page_type = 'CART') as has_mto_on_cart,
        max(array_contains(event_list_arr, '705') and page_type = 'CART') as has_oos_on_cart,
        max(regexp_like(page_url, 'p-CART:m-RV')) as has_rv_carousel_on_cart,
        max(regexp_like(page_url, 'p-CART:m-FBT')) as has_fbt_carousel_on_cart,
        max(exists(engagements, x -> x rlike 'team-widget') and page_type = 'CART') as has_team_widget_on_cart,
        max(array_contains(event_list_arr, '658') and page_type = 'CART') as has_instock_on_cart,
        max(array_contains(event_list_arr, '659') and page_type = 'CART') as has_dropship_on_cart,
        max(array_contains(event_list_arr, '700') and page_type = 'CART') as has_presell_on_cart,
        -- final_cart_net_value, -- see final_cart_net_total
        -- final_cart_gross_value, -- see final_cart_gross_total
        -- final_cart_units, -- see final_cart_unit_total

        -- HOME OF THE JERSEY GRID AND PDP
        count(case when upper(available_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)' and is_jer_pid then request_correlation_id end) as core_size_pid_views_on_jer_pdp,
        count(case when upper(unavailable_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)' and is_jer_pid then request_correlation_id end) as core_size_oos_pid_views_on_jer_pdp,
        max(array_contains(event_list_arr,'88') and is_jer_pid ) as has_ja_eligible_on_jer_pdp,
        max(not array_contains(event_list_arr, '255') and not upper(unavailable_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)' and is_jer_pid) as has_size_viability_on_jer_pdp,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'product-(details|description|shipping-details)') and is_jer_pid) as has_prod_accordion_clicks_on_jer_pdp,
        max(exists(engagements, x -> x rlike '\b(right|left|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and is_jer_pid) as has_visual_confirmation_on_jer_pdp,
        max(array_contains(event_list_arr,'211') and is_jer_pid) as has_coupon_elig_on_jer_pdp,
        max(exists(engagements, x -> x rlike 'more-info|PDP.*value-prop-grid') and is_jer_pid) as has_ja_clicks_on_jer_pdp,
        max(array_contains(event_list_arr, '121') and is_jer_pid) as has_topnav_on_jer_pdp,
        max(array_contains(event_list_arr, '1') and is_jer_pid) as has_search_on_jer_pdp,
        max((array_contains(event_list_arr, '240') or array_contains(event_list_arr, '242') or exists(engagements, x -> x rlike 'rating-link-') ) and is_jer_pid) as has_viewed_ratings_reviews_on_jer_pdp,
        max(exists(engagements, x -> x rlike 'pdp-size-chart-link') and is_jer_pid) as has_pdp_image_color_interaction_on_jer_pdp,
        max(is_jer_grid) as has_jersey_grid_seen,
        max(page_type in ('PDP', 'FPP') and is_jer_pid) as has_jer_product_pages_seen,
        max(array_contains(event_list_arr, '267') and is_jer_pid) as has_rv_carousel_on_jer_pdp,
        max(array_contains(event_list_arr, '645') and is_jer_pid) as has_ymal_carousel_on_jer_pdp,
        -- max(null /* todo: define tracking logic from: how do we ensure consistency in them clicking rv from these products? link engagement tracking gets wonky with reorder tests */) as has_rv_carousel_engagement_on_jer_pdp,
        -- max(null /* todo: define tracking logic from: how do we ensure consistency in them clicking rv from these products? link engagement tracking gets wonky with reorder tests */) as has_ymal_carousel_engagement_on_jer_pdp,
        -- max(null /* todo: tracking not implemented */) as has_product_layout_grid_hit,
        -- max(null /* todo: tracking not implemented */) as has_content_layout_grid_hit,
        -- max(null /* todo: tracking not implemented */) as has_product_grid_engagement,
        max(exists(engagements, x -> x rlike 'topnav-group-o-') and is_jer_grid) as has_league_team_topnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'topnav-group-ga-') and is_jer_grid) as has_gender_age_topnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'topnav-(group-d-|mnLnk-|o-)') and is_jer_grid) as has_department_topnav_on_jer_grid,
        max(array_contains(event_list_arr, '1') and is_jer_grid) as has_search_on_jer_grid,
        max(exists(engagements, x -> x rlike 'cart-icon') and is_jer_grid) as has_cart_icon_on_jer_grid,
        max(exists(engagements, x -> x rlike 'team-widget') and is_jer_grid) as has_team_widget_on_jer_grid,
        max(array_contains(event_list_arr, '121') and is_jer_grid) as has_topnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-leagues') and is_jer_grid) as has_league_team_leftnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-gender-age') and is_jer_grid) as has_gender_age_leftnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*-departments') and is_jer_grid) as has_department_leftnav_on_jer_grid,
        max(exists(engagements, x -> x rlike 'side-nav.*' and NOT (x rlike 'side-nav.*-(leagues|gender-age|departments)')) and is_jer_grid) as has_other_leftnav_on_jer_grid,
        max(array_contains(event_list_arr, '105') and is_jer_grid) as has_pills_on_jer_grid,
        max(exists(engagements, x -> x rlike 'static-sort-dropdown|page-|pagination') and is_jer_grid) as has_pagination_on_jer_grid,
        max(exists(engagements, x -> x rlike 'top-breadcrumbs') and is_jer_grid) as has_breadcrumbs_on_jer_grid,
        max(exists(engagements, x -> x rlike 'site-logo') and is_jer_grid) as has_site_logo_on_jer_grid,
        max(search_result_count > 5000 and is_jer_grid) as has_over_5000_products_on_jer_grid,
        max(search_result_count > 1000  and  search_result_count <= 5000 and is_jer_grid) as has_between_1000_5000_products_on_jer_grid,
        max(search_result_count > 200  and  search_result_count <= 1000 and is_jer_grid) as has_between_200_1000_products_on_jer_grid,
        max(search_result_count <= 200 and is_jer_grid) as has_under_200_products_on_jer_grid,
        max(array_contains(event_list_arr, '259') and is_jer_pid) as has_breadcrumbs_on_jer_pdp,
        max(exists(engagements, x -> x rlike '\b(right|left|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and is_jer_pid) as has_image_clicked_on_jer_pdp,
        
        -- MTO
        max(
                is_mto_pid
                and (
                        (
                                exists(engagements, x -> x rlike 'custom-options-form' and x rlike 'name')
                                and exists(engagements, x -> x rlike 'custom-options-form' and x rlike 'number')
                        )
                        or
                        (
                                select_field_combo rlike 'custom-options-form'
                                and select_field_combo rlike 'name'
                                and select_field_combo rlike 'number'
                        )
                )
        ) AS has_custom_completion_on_mto_pdp,
        max(
                is_mto_pid
                and exists(engagements, x -> x rlike '(?i)select player')
                and not (
                        (
                            exists(engagements, x -> x rlike 'custom-options-form' and x rlike 'name')
                            and exists(engagements, x -> x rlike 'custom-options-form' and x rlike 'number')
                        )
                and not (
                            select_field_combo rlike 'custom-options-form'
                            and select_field_combo rlike 'name'
                            and select_field_combo rlike 'number'
                        )
                )
        ) AS has_custom_dropoff_on_mto_pdp,
        max(is_mto_pid and exists(engagements, x -> x rlike '(?i)select player')) as has_custom_entry_on_mto_pdp,
        max(
                is_mto_pid
                and exists(engagements, x -> x rlike '(?i)select player')
                and not exists(engagements, x -> x rlike 'dropdown')
        ) AS has_custom_entry_friction_on_mto_pdp,
        -- max(null /* todo: define tracking logic from: would need tracking here */) as has_custom_grid_hit_on_mto_pdp,
        max(exists(engagements, x -> x rlike 'return-policy')) as has_return_policy_click_on_mto_pdp,
        count(distinct case when is_mto_pid then product_id end) as mto_pid_counts,
        count(case when is_mto_pid then request_correlation_id end) as mto_pdp_views,
        count(distinct case when is_mto_pid then product_id end) as unique_mto_pid_counts,
        max(is_mto_pid) as has_mto_pdp,
        max(exists(engagements, x -> x rlike 'shipping-policy') and is_mto_pid) as has_shipping_policy_on_mto_pdp,
        max(exists(engagements, x -> x  RLIKE 'opening') and exists(engagements, x -> x  RLIKE 'product-(details|description|shipping-details)') and is_mto_pid) as has_prod_accordion_on_mto_pdp,
        max(array_contains(event_list_arr, '121') and is_mto_pid) as has_topnav_on_mto_pdp,
        max(page_type in ('PDP', 'FPP') and is_mto_pid) as has_mto_seen,
        max(array_contains(event_list_arr, '1') and is_mto_pid) as has_search_on_mto_pdp,
        max((array_contains(event_list_arr, '240') or array_contains(event_list_arr, '242') or exists(engagements, x -> x rlike 'rating-link-')) and is_mto_pid) as has_viewed_ratingsreviews_mto_page_pdp,
        max(exists(engagements, x -> x rlike 'pdp-size-chart-link') and is_mto_pid) as has_pdp_image_or_color_interaction_mto_pdp,
        max(array_contains(event_list_arr, '267') and is_mto_pid) as has_rv_carousel_on_mto,
        max(array_contains(event_list_arr, '645') and is_mto_pid) as has_ymal_carousel_on_mto,
        -- max(null /* todo: define tracking logic from: how do we ensure consistency in them clicking rv from these products? link engagement tracking gets wonky with reorder tests */) as has_rv_carousel_engagement_mto,
        -- max(null /* todo: define tracking logic from: how do we ensure consistency in them clicking rv from these products? link engagement tracking gets wonky with reorder tests */) as has_ymal_carousel_engagement_mto,
        max(array_contains(event_list_arr, '259') and is_mto_pid) as has_breadcrumbs_mto,
        max(exists(engagements, x -> x rlike '\b(right|left|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and is_mto_pid) as has_image_clicked_on_mto_pdp,
        
        -- CHECKOUT PROGRESSION
        max(NOT exists(engagements, x -> x rlike 'cc-dropdown') and NOT (has_item_list_click OR has_browser_autofill_field OR has_checkbox_click) and page_type = 'CHKT') as has_cost_exposed_no_payment_on_chkt,
        max((array_contains(event_list_arr,'463') or array_contains(event_list_arr,'461')  or array_contains(event_list_arr,'63')) and page_type = 'CHKT') as has_checkout_friction_on_chkt,
        max((exists(engagements, x -> x rlike 'cc-dropdown') OR has_item_list_click OR has_browser_autofill_field OR has_checkbox_click) and page_type = 'CHKT') as has_payment_config_on_chkt,
        max((has_item_list_click OR has_addr_payment_field OR has_link_engagement) and page_type = 'SHPG') as has_shipping_config_on_shpg,
        max(array_contains(event_list_arr, '564') and page_type = 'CHKT') as has_digital_wallet_on_chkt,
        -- cart_s2_visitor_flag, --- has_cart_to_shpg
        -- cart_s3_visitor_flag, --- has_cart_to_chkt
        -- s2_s3_visitor_flag, --- has_shpg_to_chkt

        -- SHIPPING
        max_by(case when page_type = 'CHKT' then default_shipping_price end, timestamp_est) as default_shipping_price_chkt,
        max_by(case when page_type = 'CHKT' then default_shipping_discounted_price end, timestamp_est) as default_shipping_discounted_price_chkt,
        max_by(case when page_type = 'CHKT' then default_shipping_method end, timestamp_est) as default_shipping_method_chkt,
        max_by(case when page_type = 'CHKT' then available_shipping_method end, timestamp_est) as available_shipping_method_chkt,
        max_by(case when shipping_method is not null then shipping_method end, timestamp_est) as shipping_method_used,
        max(array_contains(event_list_arr, '176')) as has_local_hyperspeed_elig,
        max(array_contains(event_list_arr, '43')) as has_national_hyperspeed_elig,
        max(array_contains(event_list_arr, '90')) as has_upsell_elig,
        max(array_contains(event_list_arr, '78')) as has_multi_dc,
        max(array_contains(event_list_arr, '701')) as has_multi_ship_group,
        max(array_contains(event_list_arr, '659')) as has_dropship_cart,
        max(array_contains(event_list_arr, '226')) as has_markdown_flag,
        max(array_contains(event_list_arr, '703')) as has_multi_ship_group_eig,
        max(array_contains(event_list_arr, '29')) as has_oversized_freight,
        max(array_contains(event_list_arr, '700')) as has_presell_cart,
        max(array_contains(event_list_arr, '227') and not (array_contains(event_list_arr, '462') or array_contains(event_list_arr, '464'))) as has_entry_fs_coupon_applied,
        max(array_contains(event_list_arr, '227') and (array_contains(event_list_arr, '462') or array_contains(event_list_arr, '464'))) as has_fs_coupon_applied_chkt,
        max(array_contains(event_list_arr, '225')) as has_total_savings_chkt,
        max(array_contains(event_list_arr, '246')) as has_chkt_pdd_elig,
        max(array_contains(event_list_arr, '639')) as has_chkt_dynamic_pdd_elig,
        max(array_contains(event_list_arr, '706')) as has_chkt_custom_cart,
        max(array_contains(event_list_arr, '215')) as has_chkt_dd_savings,
        max(array_contains(event_list_arr, '216')) as has_chkt_coupon_savings,
        max(array_contains(event_list_arr, '217')) as has_chkt_markdown_savings,
        max(array_contains(event_list_arr, '227')) as has_chkt_ship_savings,
        max(array_contains(event_list_arr, '228')) as has_chkt_discount_savings,
        -- max(final_cart_net_total_on_chkt) as final_cart_net_total_on_chkt,
        -- max(final_cart_gross_total_on_chkt) as final_cart_gross_total_on_chkt,
        -- max(final_cart_unit_total_on_chkt) as final_cart_unit_total_on_chkt,
        
        -- DTI/FPP
        max(array_contains(event_list_arr, '255') and page_type = 'FPP') as has_oos_product_view_on_fpp,
        max(array_contains(event_list_arr, '256') and page_type = 'FPP') as has_fullstock_product_view_on_fpp,
        coalesce(sum(case when page_type='FPP' then cardinality(split(available_sizes, ',')) else 0 end), 0) as available_sizes_count_on_fpp,
        coalesce(sum(case when page_type='FPP' then cardinality(split(unavailable_sizes, ',')) else 0 end), 0) as unavailable_sizes_count_on_fpp,
        max(exists(engagements, x -> x rlike 'pdp-size-chart-link') and page_type = 'FPP') as has_size_chart_on_fpp,
        max(exists(engagements, x -> x rlike 'color-selector|\b(right|zoom-modal-icon|pinch_zoom_in)\b|update-thumbnail-') and page_type = 'FPP') as has_image_color_interaction_on_fpp,
        max(regexp_like(page_url, 'p-FPP:m-RV')) as has_rv_carousel_on_fpp,
        max(array_contains(event_list_arr, '121') and page_type = 'FPP') as has_topnav_on_fpp,
        max(regexp_like(page_url, 'p-FPP:m-featured-department')) as has_fd_carousel_on_fpp,
        max(regexp_like(page_url, 'p-FPP:m-TS')) as has_ts_carousel_on_fpp,
        max(regexp_like(page_url, 'p-FPP:m-CAV')) as has_cav_carousel_on_fpp,
        max(array_contains(event_list_arr, '1') and page_type = 'FPP') as has_search_on_fpp,
        max(exists(engagements, x -> x rlike 'image_(zoom|viewer)|size-chart-link|product-(details|description|shipping-details)|rating-link-') AND page_type = 'FPP') as has_information_clarity_on_fpp,
        max((array_contains(event_list_arr, '144') or ((array_contains(event_list_arr, '140') or array_contains(event_list_arr, '141')) and array_contains(event_list_arr, '602'))) and page_type = 'FPP') as has_value_saving_on_fpp,
        max((array_contains(event_list_arr, '84') or array_contains(event_list_arr, '135') or array_contains(event_list_arr, '426')) and page_type = 'FPP') as has_shipping_value_on_fpp,
        max((array_contains(event_list_arr, '255') OR upper(unavailable_sizes) RLIKE '(^|[^A-Z0-9])(X|M|L)([^A-Z0-9]|$)') and page_type = 'FPP') as has_structural_health_on_fpp,
        max((array_contains(event_list_arr, '1') or array_contains(event_list_arr, '121') or array_contains(event_list_arr, '259')) and page_type = 'FPP') as has_navigation_on_fpp,
        max(regexp_like(page_url, 'p-FPP.*(m-RV|m-TD|m-TS|m-FD|m-CAV)')) as has_recommendations_on_fpp,
        max(exists(engagements, x -> x rlike 'team-widget') and page_type = 'FPP') as has_team_widget_on_fpp,
        min(case when page_type = 'FPP' then request_correlation_id end) != max(case when page_type = 'FPP' then request_correlation_id end) as has_pogo_on_fpp,

        -- PRICING & PROMO
        -- max(null /* todo: tracking not implemented */) as has_coupon_eligible_carts,
        max((array_contains(event_list_arr, '461') or array_contains(event_list_arr, '462') or array_contains(event_list_arr, '463') or array_contains(event_list_arr, '464')) and page_type ='CART') as has_coupon_usage_on_cart,
        max((array_contains(event_list_arr, '461') or array_contains(event_list_arr, '462') or array_contains(event_list_arr, '463') or array_contains(event_list_arr, '464')) and page_type ='CHKT') as has_coupon_usage_on_chkt,
        max((array_contains(event_list_arr, '462') or array_contains(event_list_arr, '464')) and page_type ='CART') as has_coupon_successful_usage_on_cart,
        max((array_contains(event_list_arr, '462') or array_contains(event_list_arr, '464')) and page_type ='CHKT') as has_coupon_successful_usage_on_chkt,
        max((array_contains(event_list_arr, '461') or array_contains(event_list_arr, '463')) and page_type ='CART') as has_coupon_unsuccessful_usage_on_cart,
        max((array_contains(event_list_arr, '461') or array_contains(event_list_arr, '463')) and page_type ='CHKT') as has_coupon_unsuccessful_usage_on_chkt,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_clearance_units,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_dropship_units,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_markdown_units,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_promo_units,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_elig_promo_units,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_coupon_elig_order,
        -- max(null /* todo: ignore - use order_ref_num to join to WT */) as has_coupon_order,
        max(array_contains(event_list_arr, '25')) as has_promo_qualifier_cart_visits,
        max(array_contains(event_list_arr, '26')) as has_promo_qualifier_chkt_visits
        
        -- SUCCEED
        -- max(null /* todo: tracking not implemented */) as has_track_order_button_click,
        -- max(null /* todo: tracking not implemented */) as has_help_page_visit,
        -- max(null /* todo: tracking not implemented */) as has_return_initiation,
        -- max(null /* todo: tracking not implemented */) as has_return_completion

from page_views
    group by 1,2,3,4
), final as (

  SELECT
    d.*,
    page_num_max =1 as is_single_page_visitor,
    case when visit_num =1 then 'new' else 'returning' end as visitor_type,
     /* - funnel flags */ /* - ever viewed */
    contains(pages_grouped, 'H') AS hp_viewed,
    contains(pages_grouped, 'G') AS grid_viewed,
    pages_grouped rlike 'P|F' AS product_page_viewed,
    contains(pages_grouped, '1') AS cart_viewed, 
    pages_grouped like 'H%'  AS is_hp_entry,
    pages_grouped like 'G%'  AS is_grid_entry,
    pages_grouped like 'P%'  AS is_pdp_entry, 
    pages_grouped like 'F%'  AS is_fpp_entry,
    pages_grouped RLIKE 'H.*P' AS has_hp_to_pdp,
    pages_grouped RLIKE 'H.*G' AS has_hp_to_grid,
    pages_grouped RLIKE 'H.*1' AS has_hp_to_cart,
    pages_grouped RLIKE 'G.*P' AS has_grid_to_pdp,
    pages_grouped RLIKE 'G.*1' AS has_grid_to_cart,
    pages_grouped RLIKE '1.*4' AS has_cart_to_thku,
    pages_grouped RLIKE '2.*4' AS has_shpg_to_thku,
    pages_grouped RLIKE '3.*4' AS has_chkt_to_thku,
    pages_grouped RLIKE '1.*2' AS has_cart_to_shpg,
    pages_grouped RLIKE '1.*3' AS has_cart_to_chkt,
    pages_grouped RLIKE '2.*3' AS has_shpg_to_chkt, 

    pages_grouped RLIKE 'A' AS has_cart_activity,
    first_filter_clicks is not null and first_filter_clicks < first_cart_activity AS has_filter_to_cart_activity,
    first_topnav_clicks is not null and first_topnav_clicks < first_cart_activity AS has_topnav_to_cart_activity,
    first_leftnav_clicks is not null and first_leftnav_clicks < first_cart_activity AS has_leftnav_to_cart_activity,
    first_global_topnav_clicks is not null and first_global_topnav_clicks < first_cart_activity AS has_global_topnav_to_cart_activity,
    first_global_topnav_team_clicks is not null and first_global_topnav_team_clicks < first_cart_activity AS has_global_topnav_team_to_cart_activity,
    first_global_topnav_non_team_clicks is not null and first_global_topnav_non_team_clicks < first_cart_activity AS has_global_topnav_non_team_to_cart_activity,
    first_team_topnav_clicks is not null and first_team_topnav_clicks < first_cart_activity AS has_team_topnav_to_cart_activity,

    pages_grouped RLIKE 'S.*P' AS has_srp_to_pdp,
    pages_grouped RLIKE 'H.*A' AS has_hp_to_cart_activity,
    pages_grouped RLIKE 'G.*A' AS has_grid_to_cart_activity,
    first_jer_grid_views is not null and first_jer_grid_views < first_cart_activity AS has_jer_grid_page_to_cart_activity,
    pages_grouped RLIKE '(P|F).*A' AS has_product_page_to_cart_activity,
    pages_grouped RLIKE 'P.*A' AS has_pdp_to_cart_activity,
    pages_grouped RLIKE 'F.*A' AS has_fpp_to_cart_activity,
    first_jer_pid_views is not null and first_jer_pid_views < first_cart_activity AS has_jer_product_page_to_cart_activity,
    first_mto_pid_views is not null and first_mto_pid_views < first_cart_activity AS has_mto_product_page_to_cart_activity,
    pages_grouped RLIKE 'S.*A' AS has_search_to_cart_activity,
    pages_grouped RLIKE 'T.*A' AS has_typeahead_to_cart_activity,

    w.net_demand_usd,
    w.contribution_margin_usd,
    w.contribution_margin_less_fixed_costs_usd,
    w.outbound_freight_usd,
    w.ordered_quantity,
    w.sales_cntry_cd,
    w.ship_city,
    w.ship_state,
    w.ship_cntry_cd,
    w.ship_zip_cd,
    w.admin_crncy_cd,
    w.net_demand,
    w.contribution_margin,
    w.contribution_margin_less_fixed_costs,
    w.internal_surrogate_key,
    unix_seconds(now()) as run_ts
    from dv d
    left join wts w
    using (order_ref_num, site_id)
)

select * from final