#' ---
#' title: "Culvert Cost Machine Learning Methods"
#' author: "B. Van Deynze"
#' date: '`r format(Sys.Date(), "%B %d, %Y")`'
#' output:
#'    html_document:
#'       number_sections: true
#'       code_folding: hide
#'       toc: true
#'       toc_float:
#'          collapsed: true
#' ---
#' 
#+ include=F

# Based loosely on Ch. 9-12 of Boehmke & Greenwell (https://bradleyboehmke.github.io/HOML/)

#+
#' The goal of these exercises is to explore machine learning methods to improve
#' out-of-sample prediction of culvert improvement costs over predictions from
#' OLS estimates of log-linear average cost models. We loosely follow the methods presented in 
#' *Hands-On Machine Learning in R* by Bradley Boehmke and Brandon Greenwell (available [here](https://bradleyboehmke.github.io/HOML/)).  
#' 

#' In this process, we split the culvert project cost data randomly into a
#' training and testing set. We then "train" models on the training set,
#' including OLS estimates for comparison. We then "test" these models by
#' computing and comparing Root Mean Square Error (RMSE) of the out-of-sample
#' predictions of the test set.  
#' 

#' We consider three related machine learning methods. First, we generate a
#' single regression tree, a method that partitions the data into groups with
#' similar response values (i.e. log average costs) based on discrete splits in
#' the explanatory variables (i.e. land cover is developed or bankfull width is
#' greater than three meters). This partitioning process continues until a
#' stopping point is reached, based either on some penalization per additional
#' "branch" or a set number of splits. Predictions are made by assigning the
#' median value within each group to all members of that group. We compare RMSE
#' across a number of limits to the number of branches, a process known as "pruning."
#' 

#' We then consider a "bagging" technique known as a random forest (RF), a
#' model-averaging procedure based on bootstrapping ("bagging" is short for
#' "bootstrap aggregating"). This method works by repeatedly randomly selecting
#' a subsample of the training set along with a random selectinon of the
#' potential explanatory varaibles and fitting regression trees for each
#' subsample-variables pair. The final prediction is the mean prediction for
#' each component tree, hence "random forest."  
#' 

#' Finally, we consider the boosted regression tree (BRT) method. This method works
#' through sequential training. A single regression tree is fit to the data, and
#' then a second regression tree is fit to the residuals of the first tree. The
#' predictions from these two models are added together to form an ensemble
#' model, and the residuals from that model are then subsequently fit for an
#' additional tree, and so on and so forth until a stopping point is reached.  
#' 

#' We compare testing RMSE and plots of predicted and actual values for each
#' method (including OLS) to determine the preferred method to use in cost
#' predictions out-of-sample (e.g., on the WDFW culvert inventories).  
#'

#' Then, we examine the variables most important to prediction in both of the
#' preferred ML fits. These "importance" metrics are measured as the sum of
#' squared decreases in RMSE at each "node" a variable is associated with across
#' the component models of each fit. This exercise reveals patterns of important
#' predictors quite similar to the set of explanatory variables selected for the
#' OLS fit.  
#' 

#' Note that for all methods other than OLS, we provide as an input a nearly
#' complete list of explanatory variables based on the full suite of potentially
#' relevant variables considered throughout the study. This list is presented
#' below.  
#' 

#+ include=FALSE
# Prepare environment and data ----
rm(list = ls())


library(searchable)
library(tidyverse)
library(janitor)
library(here)
library(readxl)
library(sandwich)
library(lmtest)
library(vip)
library(pdp)
library(knitr)
library(kableExtra)

# Load NLCD key
key_nlcd <-
  read_xlsx(
    here(
      "/data/Culverts spatial overlays v 20Jan2021.xlsx"
    ), 
    sheet = 3
  ) %>% 
  as_tibble() %>%
  clean_names() %>%
  rename(
    nlcd_current_class = class,
    nlcd_current_fullclass = classification
  ) %>%
  mutate(across(where(is_character), str_to_sentence)) %>%
  filter(across(description, ~!str_detect(., "Alaska only"))) %>%
  select(-description)

# Load data
df_culv <-
  read_csv(here("output", "culverts_pure_modelling.csv")) %>%
  mutate(
    project_year = ordered(project_year),
    project_source = relevel(factor(project_source), ref = "OWRI"),
    basin = relevel(factor(basin), ref = "SOUTHERN OREGON COASTAL"),
    fips = factor(fips),
    state_fips = factor(state_fips),
    here_class = as.character(here_class),
    here_speed = relevel(factor(here_speed), ref = 6),
    tot_dist = I(n_worksites * dist_mean)
  ) %>%
  left_join(
    key_nlcd, 
    by = c("nlcd_current" = "value")
  ) %>%
  filter(
    !(nlcd_current_class %in% c("Barren", "Water")),
    tot_dist < 10000
  ) %>%
  mutate(
    nlcd_current_class = relevel(factor(nlcd_current_class), ref = "Forest")
  )

df_culv_full <-
  read_csv(here("output", "culverts_full_spatial.csv")) %>%
  # group_by(project_id) %>%
  # mutate(
  #   n_worksites = n()
  # ) %>%
  # ungroup() %>%
  mutate(
    project_year = ordered(project_year),
    project_source = relevel(factor(project_source), ref = "OWRI"),
    basin = relevel(factor(basin), ref = "SOUTHERN OREGON COASTAL"),
    fips = factor(fips),
    state_fips = factor(state_fips),
    here_class = as.character(here_class),
    here_speed = relevel(factor(here_speed), ref = 6),
    tot_dist = 0,
    dist_mean = 0,
    dist_max = 0,
    n_worksites = 1,
    n_culverts = 1,
    action_fishpass_culvimp_prj = 1,
    action_fishpass_culvinst_prj = 0,
    action_fishpass_culvrem_prj = 0,
    action_fishpass_culvimp_wrk = 1,
    action_fishpass_culvinst_wrk = 0,
    action_fishpass_culvrem_wrk = 0,
    action_fishpass_culvimp_count_prj = 1,
    action_fishpass_culvinst_count_prj = 0,
    action_fishpass_culvrem_count_prj = 0,
    action_fishpass_culvimp_count_wrk = 1,
    action_fishpass_culvinst_count_wrk = 0,
    action_fishpass_culvrem_count_wrk = 0,
  ) %>%
  left_join(
    key_nlcd, 
    by = c("nlcd_current" = "value")
  ) %>%
  filter(
    !(nlcd_current_class %in% c("Barren", "Water")),
    tot_dist < 10000
  ) %>%
  mutate(
    nlcd_current_class = relevel(factor(nlcd_current_class), ref = "Forest")
  )
  
  

names(df_culv)

# Estimators for conditional cost distributions ----

# __ Basic OLS estimator ----
# Full model
mod_full <- 
  lm(
    log(cost_per_culvert) ~
    # log(I(adj_cost / n_worksites)) ~
      # Scale/scope of project controls: number of culverts, distance between worksites, type of culvert work
      n_worksites * tot_dist + # factor(I(n_worksites == 1)) +
      action_fishpass_culvrem_prj + action_fishpass_culvinst_prj +
      # Stream features at worksite: slope, bankfull width
      slope * bankfull_width + 
      # Road features at worksite: paved, road class
      factor(here_paved) + factor(here_speed) +
      # Physical features of worksite: terrain slope, land cover
      # slope_deg + factor(nlcd_current_class) +
      cat_basin_slope + cat_elev_mean + factor(nlcd_current_class) +
      # Population features: housing density, jobs in construction, jobs in ag/forestry
      hdens_cat + emp_const + emp_agforest + ua_dist + # factor(publand) +
      # Supplier density
      # merch_totp + 
      const_totp +
      brick_totp +
      metal_totp +
      sales_coun +
      # sand_count +
      # Land ownership
      # pvall_1km_buff +
      pv_1km_buff +
      pvi_1km_buff +
      pvn_1km_buff +
      # stall_1km_buff +
      # I(fedother_1km_buff +
      # blm_1km_buff +
      # usfs_1km_buff +
      # lg_1km_buff +
      # Fixed effects
      basin + factor(project_year) + project_source,
    df_culv
  )

coeftest(
# summary(
  mod_full, 
         vcov. = vcovCL(mod_full, cluster = ~ project_id, type = "HC3")
         # vcov. = vcovHC(mod_full)
)

# __ Try ML models ----
library(MASS)
set.seed(1)


# Select just dependent variable and possible features, plus fix character/categorical variables as factors
(
  df_tree <-
    df_culv %>%
    dplyr::select(
      -c(project_id:subbasin),
      -adj_cost, -pure_culv, -county, -state_fips, -ua_nn_name, -uc_nn_name, -fips, -ends_with("_nodata"), -c(id:tot_s1830), -c(nlcd_2001:nlcd_2016), -c(snet_distm:snet_name), -hu_mod,
      -geometry, -huc12, -huc12_name, -comid, -to_huc12, -c(nhd_dist_m:nhd_ftype),
      cost_per_culvert
    ) %>%
    mutate(
      across(c(here_speed:here_publi, here_class_0:here_paved_0), factor),
      project_year = ordered(project_year)
    ) %>%
    mutate(
      across(where(is.character), factor)
    )
) %>%
  ungroup() %>%
  summarize(across(everything(), ~sum(is.na(.)))) %>%
  pivot_longer(everything()) %>%
  arrange(-value)
# Only 802 of 1,249 not missing any variables we keep (could dig deeper into what's dropped here to build up to larger sample)
# Main culprits are: here_class_namatch, emp_mgmn, emp_mining, snet_use, emp_educ, and emp_util
# Also drop a few variables that are misclassified or definitions are unclear
(
  df_tree <-
    df_tree %>%
    dplyr::select(-c(here_class_namatch, emp_mgmn, emp_mining, snet_use, snet_spp, emp_educ, emp_util, nlcd_current, tot_total_road_dens)) %>%
    drop_na()
) %>% count()
  
#+ echo=FALSE
read_csv(here("data/key_variables.csv")) %>%
  replace_na(list(ols = "")) %>%
  rowwise() %>%
  mutate(ols = str_to_upper(ols)) %>%
  rename("Label" = 1, "Description" = 2, "Included in OLS?" = 3) %>%
  kable(
    align = "llc",
    caption = paste("Explanatory variables included in machine learning fits, N =", scales::comma(nrow(df_tree)))
  ) %>%
  kable_styling(fixed_thead = TRUE)
  

#+
#' # Machine learning methods  
#' ## Regression tree  
#' 

#' We start with a number of simple regression trees. To begin, we randomly
#' assign half the sample to a "training" set which we will use to fit the
#' models.  
#' 

#+ warning=F, message=F
# Select training group (half the total observations, used to build the model, remaining obs are used as out-of-sample test group)
set.seed(1)
train = sample(1:nrow(df_tree), nrow(df_tree)/2)

#' Then, we use the `rpart` package to fit and plot a regression tree using the training data.  
#' 

#+ warning=F, message=F, fig.width=8, fig.height=10
# ____ Build a single regression tree ----
library(rpart)
library(rpart.plot)
set.seed(1)
tree_culv <- rpart(log(cost_per_culvert) ~ ., df_tree, subset = train)
rpart.plot(tree_culv, digits = 3)

#' In each "leaf" the number is the median log(cost) of all worksites in the set
#' that passes all the qualifiers above Each "branch" assigns worksites to the
#' left if it passes the qualifier, right otherwise (YES --> left; No -->
#' right), and the percent of the sample assigned to each node. Fixed effects
#' like project source and basin appear important, though which other variables
#' are selected for splits is highly dependent on the specific sample randomly
#' chosen for the training set. That said, some variables such as distance to
#' urban areas, distance between worksites, land cover, land ownership, and
#' employment measures are all represented in ways similar to the OLS results.
#' 

#' Note that the `rpart` package automatically "prunes" the tree to the
#' "optimal" number of leaves using a 10-fold cross validation, using different
#' complexity cost parameters and comparing the relative error on the testing
#' set and selecting the number of nodes that minimizes that error (or a
#' meaningful improvements are not found my increasing the number of leaves). We
#' can look at the relative error as a function of the complexity cost parameter
#' (cp, which in effect limits the number of leaves).  
#' 
plotcp(tree_culv)

#' It looks like using the default 21 leaf tree in fact might be over-fitting
#' the model, so we will also look at a smaller four-leaf tree, which looks like
#' it should provide better predictions.  
#' 
tree_culv_4 <- rpart(log(cost_per_culvert) ~ ., df_tree, subset = train, control = list(cp = 0.025))
rpart.plot(tree_culv_4, digits = 3)

#' In this smaller tree, reporting source, land cover, and the total distance
#' between worksites are the variables used to split the sample. Note that
#' tot_dist has a counter intuitive effect: worksites further apart from other
#' worksites under the same project are cheaper. Note that this is likely
#' because tot_dist is proxying for the number of worksites here. Projects with
#' only one worksite that do not benefit from scale economies will have tot_dist
#' values of zero, and so this effect is captured by the distance.  

#+ include=FALSE
# Predictions
# Let's see how the 5 leaf tree, 18 leaf tree, and full 25 leaf tree perform on the test group, by computing the root mean square error
yhat_culv_4 = predict(tree_culv_4, newdata = df_tree[-train,])
y_test = df_tree[-train, "cost_per_culvert"]
(rmse_tree4 <- sqrt(sum((yhat_culv_4 - log(y_test)) ^ 2)/length(yhat_culv_4)) %>% c("Root Mean Square Error" = .))
plot(x = yhat_culv_4, y = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)
# Not pretty, but it's something! Let's try again with the other trees
yhat_culv = predict(tree_culv, newdata = df_tree[-train,])
(rmse_treefull <- sqrt(sum((yhat_culv - log(y_test)) ^ 2)/length(yhat_culv)) %>% c("Root Mean Square Error" = .))
plot(x = yhat_culv, y = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)
# And the RMSE is just as bad

# Finally, we'll do the same with the OLS model
mod_train <- update(mod_full, data = df_tree[train,])
yhat_culv_ols = predict(mod_train, newdata = df_tree[-train,])
(rmse_ols <- sqrt(sum((yhat_culv_ols - log(y_test)) ^ 2)/length(yhat_culv_ols)) %>% c("Root Mean Square Error" = .))
plot(x = yhat_culv_ols, y = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)

# The RMSE is about the same as the smallest tree, even a bit better

#+
#' One thing to think about is that project year, project source, and the
#' number of worksites are all variables impossible to really observe for true
#' out-of-sample culverts. These variables drive a lot of the cost variation, but
#' the OLS model with fixed effects allows us to make predictions out-of-sample
#' by "averaging" over these effects. We can do this for the trees too, but not
#' sure it will be as useful if these features/variables drive most of the
#' prediction (as is the case with the four leaf tree).  
#' 

#+ echo=FALSE
#' ## Random forest (RF)  

#' This method uses "bagging", or bootstrap aggregating, to boostrap sample the
#' training set a fixed number (N) of times (1,000 here) and generate a tree
#' using a fixed number (M) of randomly selected candidate variables. The
#' resulting model averages predictions over all the generated trees in the
#' "forest".

#+ warning=F, message=F
# ____ Fit random forest ----
library(randomForest)
set.seed(1)
bag_culv <- randomForest(log(cost_per_culvert) ~ ., data = df_tree, subset = train, mtry = 25, ntree = 1000, importance = TRUE)
# Looks like a good chance this is better than both the OLS and individual trees
write_rds(bag_culv, here("output/costfits/randomforest.rds"))

#' Because these fits aggregate hundreds of trees like those seen in the
#' preceding section, they are vastly less interpretable. We will look at the
#' relative importance of the explanatory variables across the models later in this report.  

#+ include=FALSE
# Predictions
yhat_culv_bag = predict(bag_culv, newdata = df_tree[-train,])
(rmse_bag <- sqrt(sum((yhat_culv_bag - log(y_test)) ^ 2)/length(yhat_culv_bag)) %>% c("Root Mean Squared Error" = .))
# Even lower root mean square error than OLS or the individual trees
plot(y = yhat_culv_bag, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)
# Looking better... but consistently underestimates costs at high level and over estimates at low end

importance(bag_culv) %>% as_tibble(rownames = "var") %>% arrange(-`%IncMSE`) %>% print(n=Inf)
varImpPlot(bag_culv)
# Most important vars, in terms of decreasing MSE and increasing node purity (consistency w/i nodes)...
# Basin and source effects
# Private industry landownership nearby (i.e. forestry, various measures [pvi_Xkm_buff])
# Project year
# Accumulated upstream length (various measures [upst_dist, tot_stream_length, acc_stream_length])
# BFI (flow index, accumulated upstream catchments [acc])
# Elevation (in upstream catchments and locally [cat_elev_mean])
# Pop density (including employment "emp" measures)
# Material supplier density (const/brick/metal_totp)
# Basin slope (upstream catchments)
# Scale effects like total distance between worksites and number of worksites (tot_dist, dist_max, dist_mean)
# Distance to nearest road (here_distm)

# These are a lot of the variables we found important in the OLS model

# Try some tuning
# Tune m
bag_culv_m50 <- randomForest(log(cost_per_culvert) ~ ., data = df_tree, subset = train, mtry = 50, ntree = 1000, importance = TRUE)
bag_culv_m100 <- randomForest(log(cost_per_culvert) ~ ., data = df_tree, subset = train, mtry = 50, ntree = 1000, importance = TRUE)


yhat_culv_bag_m50 = predict(bag_culv_m50, newdata = df_tree[-train,])
(rmse_bag_m50 <- sqrt(sum((yhat_culv_bag_m50 - log(y_test)) ^ 2)/length(yhat_culv_bag_m50)) %>% c("Root Mean Squared Error" = .))
# Even lower root mean square error than OLS or the individual trees
plot(y = yhat_culv_bag_m50, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)


yhat_culv_bag_m100 = predict(bag_culv_m100, newdata = df_tree[-train,])
(rmse_bag_m100 <- sqrt(sum((yhat_culv_bag_m100 - log(y_test)) ^ 2)/length(yhat_culv_bag_m100)) %>% c("Root Mean Squared Error" = .))
# Even lower root mean square error than OLS or the individual trees
plot(y = yhat_culv_bag_m100, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)

# Still showing that weird bias at the tails as we increase mtry

# Tune ntree
bag_culv_ntree5000 <- randomForest(log(cost_per_culvert) ~ ., data = df_tree, subset = train, mtry = 50, ntree = 5000, importance = TRUE)
bag_culv_ntree10000 <- randomForest(log(cost_per_culvert) ~ ., data = df_tree, subset = train, mtry = 50, ntree = 10000, importance = TRUE)

yhat_culv_bag_ntree5000 = predict(bag_culv_ntree5000, newdata = df_tree[-train,])
(rmse_bag_ntree5000 <- sqrt(sum((yhat_culv_bag_ntree5000 - log(y_test)) ^ 2)/length(yhat_culv_bag_ntree5000)) %>% c("Root Mean Squared Error" = .))
# Even lower root mean square error than OLS or the individual trees
plot(y = yhat_culv_bag_ntree5000, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)


yhat_culv_bag_ntree10k = predict(bag_culv_ntree10000, newdata = df_tree[-train,])
(rmse_bag_ntree10k <- sqrt(sum((yhat_culv_bag_ntree10k - log(y_test)) ^ 2)/length(yhat_culv_bag_ntree10k)) %>% c("Root Mean Squared Error" = .))
# Even lower root mean square error than OLS or the individual trees
plot(y = yhat_culv_bag_ntree10k, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)

# Doesn't seem to change RMSE or the tail problem much

#+
#' ## Boosted regression tree (BRT)

#' This method is similar to the bagging method above in that it
#' generates a "random forest". Unlike the random forest above, each underlying
#' "tree" in the "forest" is build sequentially on the residuals of the previous
#' tree, so that each successive tree added results in improved prediction
#' accuracy of the ensemble model (the forest). It proceeds using gradient
#' descent method until it thinks it has found the global minimum for some loss
#' function (here RMSE/SSE/MSE equivalently).  
#' 

#+ warning=F, message=F
# ____ Fit boosted regression tree ----
library(gbm)
set.seed(1)

# Takes ~1min to fun on my machine
boost_culv <- gbm(log(cost_per_culvert) ~ ., data = df_tree[train,], distribution = "gaussian", n.trees = 5000, interaction.depth = 4, cv.folds = 5)
write_rds(boost_culv, here("output/costfits/boostedregression.rds"))

#' Again, these trees are difficult to interpret because they aggregate several
#' component models. Therefore, we will wait to look at relative performance and
#' variable importance until the next section.  

#+ include=FALSE
# Most important factors are...
# The fixed effects, especially source and basin
# Land use (NLCD full class)
# Distance to road (here_distm)
# Upstream distance
# Distance to urban area/urban cluster
# Basin slope
# Number of worksites
# Employment (including info+finance, probably a proxy for pop density, but esp. ag forestry which is consistent with our choices for OLS)
# Accumulated upstream slope and basin area (flow metrics)
# Private industrial land use (private forests) and BLM land in 5km buffer
# Catchment stream density, length
# Upstream and catchement road density
# Distance between culverts and number of culverts
# Density of suppliers (sales_coun)


# Again, mostly what we have in the OLS model, even closer match than the random forest results.
# Some new variables stand out, especially upstream distance and stream density measures

# We can look at the "partial" effects of each variable in the model
# 
# plot(boost_culv, i = "project_source") # Just like the fixed effects in the OLS model
# plot(boost_culv, i = "basin") # Also pretty much the same
# plot(boost_culv, i = "project_year") # Here too
# # Same patterns we see in the fixed effects models
# 
# plot(boost_culv, i = "upst_dist"); summary(df_tree$upst_dist) # The culverts with the lowest upstream distance are cheaper, but not by much and no difference after a bit
# plot(boost_culv, i = "upst_dist", xlim = c(0, 10)) # See here for predictions over the 0-75 percentile, steady increase in log(costs)
# plot(boost_culv, i = "tot_total_road_dens"); summary(df_tree$tot_total_road_dens) # Small variation here but lower upstream road density associated with lower costs (Good!)
# plot(boost_culv, i = "here_distm"); summary(df_tree$here_distm) # Further from an identified road, cheaper costs (smaller road!)
# plot(boost_culv, i = "cat_strm_dens"); summary(df_tree$cat_strm_dens) # Higher stream density, higher costs
# plot(boost_culv, i = "nlcd_current_fullclass"); summary(df_tree$nlcd_current_fullclass) # Looks like the coefficients from the OLS model
# plot(boost_culv, i = "slope"); summary(df_tree$slope) # Steeper stream, more expensive
# plot(boost_culv, i = "bankfull_width"); summary(df_tree$bankfull_width) # BFW has opposite effect we would expect, but is captured by...
# plot(boost_culv, i = "bankfull_xsec_area"); summary(df_tree$bankfull_xsec_area) # Bankfull xsection, which shows the patterns we would expect
# plot(boost_culv, i = "bankfull_xsec_area", xlim = c(0, 5)); summary(df_tree$bankfull_xsec_area) # Steeper stream, more expensive
# plot(boost_culv, i = "acc_basin_slope"); summary(df_tree$acc_basin_slope) # Steeper basins upstream, higher costs
# plot(boost_culv, i = "pvi_1km_buff"); summary(df_tree$pvi_1km_buff) # Cheaper projects near private industrial land, especially above the 75th perc.
# plot(boost_culv, i = "blm_1km_buff"); summary(df_tree$blm_1km_buff) # Similar but opposite
# plot(boost_culv, i = "n_worksites"); summary(df_tree$n_worksites) # Single worksite projects most expensive, just like in OLS model
# plot(boost_culv, i = "n_culverts"); summary(df_tree$n_culverts) # Single worksite projects most expensive, just like in OLS model
# plot(boost_culv, i = "dist_mean"); summary(df_tree$dist_mean)
# plot(boost_culv, i = "dist_max"); summary(df_tree$dist_max)
# 
# plot(boost_culv, i = "uc_dist"); summary(df_tree$uc_dist) # More expensive further from urban cluster, except at furthest distances
# plot(boost_culv, i = "ua_dist"); summary(df_tree$ua_dist) # More expensive further from urban cluster, except at furthest distances
# plot(boost_culv, i = "here_speed"); summary(df_tree$here_speed) # Lowest speed class roads are the cheapest
# plot(boost_culv, i = "here_paved"); summary(df_tree$here_paved) # Lowest speed class roads are the cheapest

# We can look at interactions, but don't find much
# plot(boost_culv, i = c("n_worksites", "tot_dist")); summary(df_tree$tot_dist) # Total distance itself doesn't have much impact
# plot(boost_culv, i = c("n_worksites", "dist_max")); summary(df_tree$dist_max) # Max distance has higher importance and we can see here evidence of a "distance-worksites" sweet spot
# 
# plot(boost_culv, i = c("slope", "bankfull_width")); summary(df_tree$slope)
# plot(boost_culv, i = c("slope", "bankfull_xsec_area")); summary(df_tree$slope); summary(df_tree$bankfull_xsec_area)
# # Looks quite a bit like our bankfull width - slope chart from the interaction effects in OLS
# # Basically in-line with what we already knew, but what about predictive power...

yhat_boost = predict(boost_culv, newdata = df_tree[-train,], n.trees = 5000)
plot(x = yhat_boost, y = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)

(rmse_boost <- sqrt(sum((yhat_boost - log(y_test)) ^ 2)/length(yhat_boost)) %>% c("Root Mean Squared Error" = .))
# Not much different than the random forest
# But the fit line looks a LOT better

# gbm.perf(boost_culv)
# best <- which.min(boost_culv$cv.error)
# sqrt(boost_culv$cv.error[best])
# So the 141st tree achieves the lowest training set RMSE (meaning we could save a lot of time during estimation)

# From here, we can adjust a bunch of the hyperparameters (the gradient descent
# rate, the number of possible leaves on each tree, the minimum observations in
# each leaf, size of the training set) and might find even better model
# performance. There are also a class of "stochastic" gradient boosting methods
# that can achieve better out of bag performance and avoid local mins by
# instituting the bootstrap techniques in bagged random forest.
#
# It might also be possible to tune the model for better performance in specific
# regions by adjusting the train/test balance or a custom loss function, but I
# have to dig deeper into the methods here.

# Tune BRT ntrees
boost_culv_n10k <- gbm(log(cost_per_culvert) ~ ., data = df_tree[train,], distribution = "gaussian", n.trees = 10000, interaction.depth = 4, cv.folds = 5)
yhat_boost_n10k = predict(boost_culv_n10k, newdata = df_tree[-train,], n.trees = 10000)
plot(y = yhat_boost_n10k, x = log(y_test) %>% pull(cost_per_culvert))
abline(0,1)

(rmse_boost_n10k <- sqrt(sum((yhat_boost_n10k - log(y_test)) ^ 2)/length(yhat_boost_n10k)) %>% c("Root Mean Squared Error" = .))

# Variable importance ----

#+
#' # Variable importance plots  
#' 

#' We present plots of relative variable importance for both RF and BRT methods.
#' Variable importance is defined as the sum of squared improvements (in mean
#' squared error) for every node where a variable is selected. For ensemble
#' models like RF and BRT, these improvements are averaged across all component
#' trees.
#' 
grid.arrange(
vip(bag_culv, num_features = 25, geom = "point", aesthetics = list(size = 4, color = scales::brewer_pal("qual", 1)(6)[5])) +
  labs(
    x = NULL, y = "Importance", title = "RF"
  ) +
  theme_bw() +
  theme(
    plot.background = element_rect(color = NULL), legend.position = "none"
  ),
vip(boost_culv, num_features = 25, geom = "point", aesthetics = list(size = 4, color = scales::brewer_pal("qual", 1)(6)[2])) +
  labs(
    x = NULL, y = "Importance", title = "BRT"
  ) +
  theme_bw() +
  theme(
    plot.background = element_rect(color = NULL), legend.position = "none"
  ),
nrow = 1
)

#' Many of the variables included in the OLS model appear within the top 25 most
#' important variables in one or both of the ML models. In particular, project
#' source and basin explain a huge amount of the variation in the data,
#' consistent with the fixed effects estimates using OLS. NLCD land cover also
#' plays a large role in both fits. Road features (speed class, distance to road
#' line) play important roles in both fits as well, consistent with the OLS
#' estimates.
#'
#' Private land managed by industry, measured at all distances, is very
#' important in the RF fit. Project scale effects like number of worksites, and
#' maximum, mean, and total distance between worksites also play important roles
#' in the RF fit, as do measures of employment by sector and supplier density.
#' In the BRT, hydrological features play a more important role, with
#' bankfull_width and slope both standing out. On the whole, the variables we
#' select for the OLS fit seem to be similar to the features that play the most
#' important role in prediction.  

#+ include=FALSE
features = unique(c(vi(bag_culv) %>% slice(1:25) %>% pull(Variable), vi(boost_culv) %>% slice(1:25) %>% pull(Variable)))

# pdpcurves <- map(features[c(4:9, 11:13, 15, 16, 18:43)], .f = function(feature) {
# partial(boost_culv, pred.var = feature, n.trees = 5000) %>% ggplot(aes(x = get(feature), y = yhat)) + geom_line() + xlab(feature)
# autoplot(pdp) + 
  # ylim(10.0, 11.5)
#   theme_light()

# })
# pdpcurves2 <- map(features[c(1:3, 10, 17)], .f = function(feature) {
  # partial(boost_culv, pred.var = feature, n.trees = 5000) %>% ggplot(aes(x = get(feature), y = yhat)) + geom_point() + xlab(feature)
    # autoplot(pdp) + 
    # ylim(10.5, 11)
  #   theme_light()
  
# })
# pdpcurves3 <- map(features[c(14)], .f = function(feature) {
  # partial(boost_culv, pred.var = feature, n.trees = 5000, plot = TRUE)
    # autoplot(pdp) + 
    # ylim(10.5, 11)
  #   theme_light()
  
# })
# grid.arrange(grobs = c(pdpcurves), ncol = 4)
# grid.arrange(grobs = c(pdpcurves2), ncol = 1)
# Compare performance ----

#+ echo=F
#' # Relative predictive power  
# __ Compare RMSE ----

#' ## Root mean square error (RMSE) by method  

#+ warning=F, message=F
tibble(
  "OLS" = rmse_ols,
  "4-leaf tree" = rmse_tree4,
  # "rmse_tree10" = rmse_tree10,
  "Full tree" = rmse_treefull,
  "RF" = rmse_bag,
  "BRT" = rmse_boost
) %>%
  pivot_longer(everything(), names_to = "method", values_to = "rmse") %>%
  ggplot(
    aes(
      x = reorder(method, rmse),
      y = rmse,
      fill = method
    )
  ) +
  geom_hline(aes(yintercept = rmse_ols), data = . %>% filter(method == "rmse_ols"), linetype = "dashed") +
  geom_col(aes(fill = method), color = "black") +
  geom_hline(yintercept = 0) +
  geom_text(aes(label = round(rmse, 3), y = rmse + 0.025)) +
  scale_fill_brewer(type = "qual") +
  # scale_color_brewer(type = "qual") +
  labs(
    x = NULL, y = "RMSE", title = "RMSE by method (testing set)",
    subtitle = "RF shows lowest RMSE, followed closely by BRT, representing ~10% and 7% increase in prediction accuracy over OLS respectively"
  ) +
  theme_bw() +
  theme(
    plot.background = element_rect(color = NULL), legend.position = "none"
  )

#' We compare RMSE calculated using the testing set (the subsample withheld
#' during fitting) to compare out-of-sample predictive power. Compared to the
#' OLS baseline, the basic regression trees actually perform somewhat worse,
#' while both of the model aggregation methods (RF and BRT) perform signficantly
#' better.  
#' 

# __ Compare fitted vs. observed plots ----
#' ## Fitted vs. actual plots  

#+ warning=F, message=F 
df_yhats <-
  tibble(
    "y" = log(df_tree$cost_per_culvert[-train]),
    "OLS" = yhat_culv_ols,
    "4-leaf tree" = yhat_culv_4,
    # "yhat_tree10" = yhat_culv_10,
    "Full tree" = yhat_culv,
    "RF" = yhat_culv_bag,
    "BRT" = yhat_boost
  ) %>%
  pivot_longer(
    -y
  )
df_yhats %>%
  ggplot(
    aes(
      x = y,
      y = value,
      fill = name
    )
  ) + 
  geom_abline(slope = 1) +
  geom_point(shape = 21, stroke = 0.4) +
  facet_wrap(~ name) +
  scale_fill_brewer(type = "qual") +
  # scale_color_brewer(type = "qual") +
  labs(
    x = "Actual cost (log-scale)", y = "Predicted cost (log-scale)", title = "Predicted vs. actual costs (testing set)",
    subtitle = "RF demonstrates an unfortunate skew"
  ) +
  theme_bw() +
  theme(
    plot.background = element_rect(color = NULL), legend.position = "none"
  ) +
  scale_x_continuous(labels = function(x) scales::dollar(exp(x)), breaks = c(log(3000), log(22000), log(150000))) + 
  scale_y_continuous(labels = function(x) scales::dollar(exp(x)), breaks = c(log(3000), log(22000), log(150000)))

#' Looking at the predictions against the actual costs per culvert values, we
#' see the limits of the simple regression trees, which places each worksite
#' into one of only a handful of bins. The aggregating methods RF and BRT
#' perform much more similarly to OLS, providing predictions distinct for each
#' worksite. Notice that while RF has a lower RMSE, it tends to over-estimate
#' costs for cheaper projects and under-estimate costs for more expensive ones,
#' which may distort the underlying variability in costs across the landscape.  
#' 

#+ include=F
# ggplot(
#   df_yhats %>% rowwise() %>% mutate(resid = y - value),
#   aes(
#     x = y,
#     y = resid,
#     color = name
#   )
# ) + 
#   geom_abline(slope = 0) +
#   geom_point() +
#   facet_wrap(~ name)

#' ## Redisual distribtuions  

#+ warning=F, message=F
df_yhats %>% mutate(resid = y - value) %>%
ggplot(
  aes(
    x = resid,
    # color = name,
    fill = name
  )
) + 
  geom_density(alpha = 0.8, color = "black") +
  geom_vline(xintercept = 0, linetype = "dashed") +
  facet_wrap(~ name) +
  scale_fill_brewer(type = "qual") +
  # scale_color_brewer(type = "qual") +
  labs(
    x = "Residual (log-cost)", y = "Density", title = "Residual distribution (testing set)", 
    subtitle = "BRT has tighter clustering of residuals near zero but wider tails"
  ) +
  theme_bw() +
  theme(
    plot.background = element_rect(color = NULL), legend.position = "none"
  ) 
  # scale_x_continuous(labels = function(x) comma(exp(x), 0.1), breaks = c(-3, -1.5, 0, 1.5, 3))

#' Here we plot the density of residuals from all five methods. Notice that BRT
#' has a tighter peak near zero compared to even the RF plot. This suggests that
#' though RF provides a lower out-of-sample RMSE, BRT predictions may more
#' consistently hit the mark. However, for BRT to display this sharp peak of
#' near zero-residuals and still have a larger RMSE, it must mean that when it
#' misses, it misses worse, indicated here by longer tails.

#+
#' # Conclusions  

#' The boosted regression tree has several desirable properties as an estimator of conditional cost distributions:  
#'   
#' 1) It provides metrics to compare variable importance and plots of conditional mean costs, allowing comparison to inference from OLS (and spatial regression)  
#' 2) While its RMSE is a bit higher (~3%) than random forest (bagging), its predictions are much tighter (RMSE growth is driven by longer tails)  
#'   

#' Further investigation is warranted to see if we can train specifically for
#' improved performance in specific areas, such as Puget Sound, for the purposes
#' of targeted planning tools.  

#+ include=F
# figtest <-
df_tree %>%
  bind_cols(
    yhat_boost = 
      predict(
        # mod_full,
        boost_culv,
        # bag_culv,
        newdata = df_tree %>%
          mutate(
            project_year = 2015,
            project_source = "WA RCO",
            # project_source = "HABITAT WORK SCHEDULE",
            project_source = factor(project_source, levels = levels(df_tree$project_source)),
            n_culverts = 1,
            tot_dist = 0,
            dist_mean = 0,
            dist_max = 0
          )
      ),
    yhat_bag = 
      predict(
        # mod_full,
        # boost_culv,
        bag_culv,
        newdata = df_tree %>%
          mutate(
            project_year = 2015,
            project_source = "WA RCO",
            # project_source = "HABITAT WORK SCHEDULE",
            project_source = factor(project_source, levels = levels(df_tree$project_source)),
            n_culverts = 1,
            tot_dist = 0,
            dist_mean = 0,
            dist_max = 0
          )
      ),
    yhat_ols = 
      predict(
        mod_full,
        # boost_culv,
        # bag_culv,
        newdata = df_tree %>%
          mutate(
            project_year = 2015,
            project_source = "WA RCO",
            # project_source = "HABITAT WORK SCHEDULE",
            project_source = factor(project_source, levels = levels(df_tree$project_source)),
            n_culverts = 1,
            tot_dist = 0,
            dist_mean = 0,
            dist_max = 0
          )
      )
  ) %>%
  dplyr::select(
    upst_dist,
    cost_per_culvert,
    yhat_ols,
    yhat_bag,
    yhat_boost
  ) %>%
  pivot_longer(
    -c(upst_dist, cost_per_culvert),
    names_prefix = "yhat_",
    names_to = "model",
    values_to = "yhat"
  ) %>%
  # rowwise() %>%
  # mutate(
  #   cost_min = min(exp(yhat_boost), cost_per_culvert),
  #   cost_max = max(exp(yhat_boost), cost_per_culvert),
  #   resid = exp(yhat_boost) - cost_per_culvert
  # ) %>%
  ggplot(
    aes(
      # x = log(cost_per_culvert),
      x = exp(yhat),
      # xmin = cost_min,
      # xmax = cost_max,
      y = upst_dist,
      # color = resid
      # color = basin,
      color = model
    )
  ) +
  # geom_density2d_filled(
  #   aes(alpha = after_stat(I(level != "(0.00, 0.05]")))
  # ) +
  # geom_linerange(alpha = 0.5) +
  geom_point(alpha = 0.5) +
  scale_alpha_manual(values = c("TRUE" = 0.8, "FALSE" = 0), guide = guide_none()) +
  scale_x_log10("Predicted Cost [$, log-scale]", labels = function(x) scales::comma(x, 1)) +
  scale_y_log10("Upstream Distance [km, log-scale]", labels = function(x) scales::comma(x, 1)) +
  scale_color_brewer(type = "qual") +
  facet_wrap("model") +
  # facet_grid(model ~ project_source) +
  # facet_wrap(~ basin) +
  # facet_wrap(~ project_source) +
  # facet_wrap(~ project_year, nrow = 3) +
  # ggthemes::theme_clean() +
  theme_bw() +
  theme(
    aspect.ratio = 1,
    text = element_text(size = 14),
    legend.position = "none"
  ) +
  labs(
    title = "Worksites in cost-benefit space", 
    subtitle = str_wrap("Some evidence of upward sloping boundary (efficiency targeting) for highest cost projects")
  )

