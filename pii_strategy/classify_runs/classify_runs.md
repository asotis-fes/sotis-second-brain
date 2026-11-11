sample_fangraph was created by running
CREATE TABLE FES_USERS.ALEX_SOTIS.CLASSIFICATION_TEST AS 
SELECT *
FROM fangraph.admin.fangraph
LIMIT 50;

sample_hashed_email_detection was created by running 

CREATE TABLE FES_USERS.ALEX_SOTIS.HASHED_EMAIL_CLASSIFICATION_TEST AS 
SELECT fangraph_id, MD5(fangraph_email) AS n_qp
FROM FES_USERS.ALEX_SOTIS.CLASSIFICATION_TEST
LIMIT 5000000

Notice that the hashed email was not detected

Need to check if Snowflake just cannot determine this, or if it is because we are passing null when running:
CALL SYSTEM$CLASSIFY('[table name]', null);