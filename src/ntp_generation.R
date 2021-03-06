# Authors ---------------------------------------------------------------------
# Daniel Buijs and Bryce Claughton
# Purpose: Scripting the collection, processing, and production of data tables
#          relating to the electronic prescribing project with 
#          Canada Health Infoway.


library(dplyr)
library(dtplyr)
library(data.table)
library(lubridate)
library(stringr)
library(magrittr)

# Get DPD extract data. set manually here
dpdextractdate <- "2017-01-16"

# For each individual ingredient, generate:
#   dpd_ing_code
#   dpd_strength_w_unit, 
#   dpd_ingredient_name, 
#   dpd_basis_of_strength_name
#   dpd_precise_name
#   ntp_therapeutic_moeity
#   imdp_g_srs
#   idmp_ucum
#   std, mapping, etc.


# For each DIN, generate:
#   ntp_code
#   ntp_ai_set, 
#   ntp_str_set, 
#   ntp_dose_form,
#   ntp_formal_desc
#   ntp_display_desc
#   ntp_status
#   ntp_tm_set
#   dpd_brand
#   dpd_company
#   dpd_form
#   dpd_route
#   dpd_status
#   dpd_ai_set
#   dpd_str_set
#   idmp_phpid_sub_l1
#   idmp_phpid_sub_l2
#   idmp_phpid_sub_l3
#   idmp_phpid_sub_l4

setwd("~/formulary/src")

# Data ------------------------------------------------------------------------

# DPDimport.R is a script that generates many useful tables from the DPD website.
source("~/formulary/src/DPDimport.R")

# Used as a filtering table for edge cases in the top 250 therapeutic moieties.
mapping_for_top_250_NA <- fread("~/formulary/src/mapping_for_top_250.csv")

# Need the active moieties (therapeutic moieties) information from the table.
us_spl_ai <- fread("~/formulary/data/ai_am_bos.csv") %>% 
  select(precise_ing = `Active Ingredient`, everything())

# Table Manipulation ----------------------------------------------------------

# Filtering drugs in the dpd by human class and are 
# currently active on the market.
dpd_human_active <- dpd_drug_all %>%
  filter(extract == "active", CLASS == "Human")

# Taking only the ingredients that are used in active human drugs.
dpd_human_active_ingredients <- dpd_ingred_all %>%
  semi_join(dpd_human_active)

# Creates a mapping for each combination of route admin and 
# pharmaceutical form for ntp.
ntp_dose_form_map <- fread("~/formulary/ntp_doseform_map.csv") %>% 
  mutate(dpd_route_admin = str_extract(V4, regex("(?<=\\().+(?=\\))")) %>%
           toupper()) %>%
  select(dpd_pharm_form = `DPD PHARMACEUTICAL_FORM`, 
         dpd_route_admin, 
         ntp_dose_form  = `NTP Formal Name Dose form`) %>%
  filter(!dpd_pharm_form == "") %T>%
  {ntp_dose_form_map_simple <<- filter(., is.na(dpd_route_admin)) %>% 
    select(dpd_pharm_form, ntp_dose_form)} %>%
  filter(!is.na(dpd_route_admin))


# For each combo of pharmaceutical form and route of administration, 
# create some basic summary statistics
dpd_form_route <- dpd_human_active %>%
  left_join(dpd_form_all) %>%
  left_join(dpd_route_all) %>%
  group_by(PHARM_FORM_CODE, ROUTE_OF_ADMINISTRATION_CODE) %>%
  dplyr::summarize(dpd_pharm_form = first(PHARMACEUTICAL_FORM),
                   dpd_route_admin = first(ROUTE_OF_ADMINISTRATION),
                   n_din = n_distinct(DRUG_IDENTIFICATION_NUMBER))


# Right join to limit dpd_pharm_form to only those in the ntp map
# Left join to include all routes of admin
# Need to figure out NAs
dpd_form_route_map <- bind_rows(right_join(dpd_form_route, ntp_dose_form_map),
                                left_join(dpd_form_route, ntp_dose_form_map_simple)) %>%
  filter(!is.na(ntp_dose_form))


# The table used for string manipulation of INGREDIENT and strength/dosage values.
# TODO (bclaught): Cleaner handling of top 250 corrections. Manual overrides
#                  should not happen.
dpd_active_ingredients <- dpd_human_active_ingredients %>%
  mutate(INGREDIENT = toupper(INGREDIENT)) %>%
  group_by(ACTIVE_INGREDIENT_CODE, INGREDIENT) %>%
  # the regex is incorrect because they have no exception. some entries do not 
  # have precise ingredients inside brackets (even though they should)
  mutate(basis_of_strength_ing = sort(unique(INGREDIENT))[1] %>% 
           str_replace(regex("(\\(.*\\)$)+?"), "") %>% 
           str_trim(),
         precise_ing = sort(unique(INGREDIENT)) %>% 
           str_extract(regex("(?<=\\()(.*)(?=\\))")) %>% 
           na.omit(.) %>% 
           paste(collapse = "|")) %>%
  mutate(precise_ing = ifelse(precise_ing == "", 
                              basis_of_strength_ing, precise_ing)) %>%
  # Top 250 Corrections  
  left_join(mapping_for_top_250_NA %>% select(c(precise_ing = dpd_values, 
                                                precise_ing_NAME_CHANGE))) %>%
  mutate(precise_ing_US = ifelse(precise_ing_NAME_CHANGE != "" & 
                                   !is.na(precise_ing_NAME_CHANGE),
                                 precise_ing_NAME_CHANGE, precise_ing)) %>%
  left_join(us_spl_ai %>% select(c(precise_ing_US = precise_ing, 
                                   `AI UNII`, `AM UNII`, `Active Moiety`))) %>%
  left_join(mapping_for_top_250_NA %>% 
              select(c(`Active Moiety` = fda_map, tm_set_map))) %>%
  mutate(`Active Moiety` = ifelse(tm_set_map != "DO NOT SHARE DRUG CODE" & 
                                    tm_set_map != "" & 
                                    !is.na(tm_set_map),
                                  tm_set_map, `Active Moiety`),
         
         `Active Moiety` = ifelse(precise_ing == "ACYCLOVIR" | 
                                    precise_ing == "ACYCLOVIR SODIUM",
                                  "ACYCLOVIR",
                                  `Active Moiety`)) %>%
  # End of Top 250 Corrections
  mutate(strength_w_unit_w_dosage_if_exists = paste0(STRENGTH, " ",
                                                     STRENGTH_UNIT, ifelse(DOSAGE_VALUE != "", paste0(" per ", DOSAGE_VALUE, " ", DOSAGE_UNIT), ""))) %>%
  select(c(DRUG_CODE, precise_ing, basis_of_strength_ing, ACTIVE_INGREDIENT_CODE,
           ai_unii = `AI UNII`, am_unii = `AM UNII`, tm = `Active Moiety`,
           STRENGTH, STRENGTH_UNIT, DOSAGE_VALUE, DOSAGE_UNIT,
           strength_w_unit_w_dosage_if_exists)) %>%
  ungroup() %>%
  distinct()


# Provides useful summary statistics for each drug code in active human drugs.
substance_sets <- dpd_active_ingredients %>%
  arrange(precise_ing, basis_of_strength_ing, STRENGTH) %>%
  group_by(DRUG_CODE) %>%
  dplyr::summarize(
    sub_set = precise_ing %>% unique() %>% paste(collapse = "!"),
    bos_set = basis_of_strength_ing %>% unique() %>% paste(collapse = "!"),
    tm_set  = tm %>% unique() %>% paste(collapse = "!"),
    sub_str_dosage_set = strength_w_unit_w_dosage_if_exists %>% unique() %>% paste(collapse = "!"),
    mp_table_set = paste(unique(basis_of_strength_ing), ifelse(unique(basis_of_strength_ing) != unique(precise_ing), paste0("(", unique(precise_ing), ")"), ""),
                         unique(strength_w_unit_w_dosage_if_exists), collapse = " and "),
    ai_unii_set = ai_unii %>% unique() %>% paste(collapse = "!"),
    am_unii_set = am_unii %>% unique() %>% paste(collapse = "!")
  )


# The products table contains product information for every drug code.
products <- dpd_human_active %>%
  select(c(DRUG_CODE, DRUG_IDENTIFICATION_NUMBER, extract, LAST_UPDATE_DATE, BRAND_NAME, NUMBER_OF_AIS)) %>%
  left_join(dpd_comp_all %>% select(c(DRUG_CODE, COMPANY_NAME, COMPANY_CODE))) %>%
  left_join(dpd_route_all) %>%
  left_join(dpd_form_all) %>%
  left_join(dpd_ther_all) %>%
  mutate(dpd_route_admin = ROUTE_OF_ADMINISTRATION,
         dpd_pharm_form  = PHARMACEUTICAL_FORM) %>%
  select(-c(ROUTE_OF_ADMINISTRATION, PHARMACEUTICAL_FORM)) %>%
  left_join(ntp_dose_form_map) %>%
  left_join(ntp_dose_form_map_simple, by = "dpd_pharm_form") %>%
  mutate(ntp_dose_form = ifelse(is.na(ntp_dose_form.x), ntp_dose_form.y, ntp_dose_form.x)) %>%
  select(-c(ntp_dose_form.x, ntp_dose_form.y))

# mp_source exists as the ultimate substance and product table.
# mp, ntp, and tm can trace their roots back to this table.
mp_source <- left_join(products, substance_sets) %>%
  mutate(product_status_effective_time = LAST_UPDATE_DATE %>%
           parse_date_time("dmy") %>%
           as.Date %>%
           str_replace_all("-", ""),
         product_status = extract)

# Contains the necessary ingredients to create the name for manufactured products.
mp_table <- mp_source %>% 
  select(c(DRUG_IDENTIFICATION_NUMBER, product_status, product_status_effective_time, 
           BRAND_NAME, COMPANY_NAME, ntp_dose_form, mp_table_set, tm_set)) %>%
  mutate(formal_description_mp = sprintf("%s [%s %s] %s",
                                         BRAND_NAME,
                                         tolower(mp_table_set),
                                         ntp_dose_form,
                                         COMPANY_NAME),
         en_display = "",
         fr_display = "")

# Contains the necessary ingredients to create the name for ntps
ntp_table <- mp_source %>%
  group_by(sub_str_dosage_set, ntp_dose_form) %>%
  dplyr::summarize(n_dins = n_distinct(DRUG_IDENTIFICATION_NUMBER),
                   #din_list = DRUG_IDENTIFICATION_NUMBER %>% unique() %>% paste(collapse = "!"),
                   formal_description_ntp = paste(tolower(mp_table_set), ntp_dose_form),
                   status = ifelse(product_status != "active", "inactive", "active"),
                   greater_than_5_AIs = NUMBER_OF_AIS > 5,
                   ntp_status_effective_time = first(sort(product_status_effective_time))) %>%
  transform(ntp_id = as.numeric(interaction(formal_description_ntp, drop=TRUE)) + 9000000) %>%
  distinct() %>%
  mutate(en_display = "",
         fr_display = "")

# Contains the necessary ingredients to create a therapeutic moiety table.
# TODO (bclaught): There is an issue with NAs appearing in the tm set.
tm_table <- mp_source %>%
  group_by(tm_set) %>%
  dplyr::summarize(n_dins = n_distinct(DRUG_IDENTIFICATION_NUMBER),
                   #din_list = DRUG_IDENTIFICATION_NUMBER %>% unique() %>% paste(collapse = "!"),
                   n_ntps = n_distinct(ntp_dose_form),
                   status = ifelse(product_status != "active", "inactive", "active"),
                   tm_status_effective_time = first(sort(product_status_effective_time))) %>%
  distinct() %>%
  transform(tm_id = as.numeric(interaction(tm_set, drop=TRUE)) + 9000000) %>%
  filter(!(tm_set %like% "\\!NA\\!")) %>% filter(!endsWith(tm_set, "!NA")) %>% filter(!startsWith(tm_set, "NA!")) %>% filter(tm_set != "NA") %>%
  mutate(formal_description_tm = str_replace_all(tm_set, "!", " and ") %>% tolower(),
         en_display = "",
         fr_display = "")

# Mapping table between TM and NTP
mapping_table <- mp_source %>%
  left_join(tm_table, by = c("tm_set")) %>%
  mutate(formal_description_ntp = paste(mp_table_set, ntp_dose_form) %>% tolower()) %>%
  left_join(ntp_table, by = c("ntp_dose_form", "formal_description_ntp", "status")) %>%
  filter(!(tm_set %like% "\\!NA\\!")) %>% filter(!endsWith(tm_set, "!NA")) %>% filter(!startsWith(tm_set, "NA!")) %>% filter(tm_set != "NA") %>%
  select(c(DRUG_IDENTIFICATION_NUMBER, ntp_dose_form, formal_description_ntp, ntp_id, tm_set, formal_description_tm, tm_id)) %>% distinct()

# Top 250 therapeutic moieties in Canada --------------------------------------  

top250 <- tbl(src_postgres("hcref", "shiny.hc.local", user = "hcreader", password = "canada1"), "rx_retail_usage") %>% 
  collect() %>%
  dplyr::select(ai_set, total) %>%
  `[`(1:250,) %>%
  as.data.table() %>%
  select(tm_set = ai_set)

top250_NAs <- top250 %>% anti_join(tm_table)
top250 <- top250 %>% semi_join(tm_table)

# Summary Tables for the top 250 ----------------------------------------------
# http://www.fda.gov/downloads/ForIndustry/DataStandards/StructuredProductLabeling/UCM362965.zip

mp_table_top250 <- mp_table %>%
  semi_join(top250) %>% 
  select(c(DRUG_IDENTIFICATION_NUMBER, formal_description_mp, en_display, fr_display, product_status, product_status_effective_time))

tm_table_top250 <- tm_table %>%
  semi_join(top250) %>%
  select(c(tm_id, formal_description_tm, en_display, fr_display, status, tm_status_effective_time))

ntp_table_top250 <- ntp_table %>%
  left_join(mapping_table) %>%
  semi_join(top250) %>%
  select(c(ntp_id, formal_description_ntp, en_display, fr_display, status, ntp_status_effective_time)) %>% distinct()

mapping_table_top250 <- mapping_table %>%
  semi_join(top250)

# Write to file ---------------------------------------------------------------

write.csv(mp_table_top250, "mp_table_top250_20170118.csv",row.names = FALSE)
write.csv(tm_table_top250, "tm_table_top250_20170118.csv",row.names = FALSE)
write.csv(ntp_table_top250, "ntp_table_top250_20170118.csv",row.names = FALSE)
write.csv(mapping_table_top250, "mapping_table_top250_20170118.csv", row.names = FALSE)


