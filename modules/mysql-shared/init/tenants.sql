-- central Tenant
CREATE DATABASE IF NOT EXISTS openmrs_central CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'central_user'@'%' IDENTIFIED BY 'central_pass';
GRANT ALL PRIVILEGES ON openmrs_central.* TO 'central_user'@'%';

-- coast Tenant
CREATE DATABASE IF NOT EXISTS openmrs_coast CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'coast_user'@'%' IDENTIFIED BY 'coast_pass';
GRANT ALL PRIVILEGES ON openmrs_coast.* TO 'coast_user'@'%';

-- eastern Tenant
CREATE DATABASE IF NOT EXISTS openmrs_eastern CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'eastern_user'@'%' IDENTIFIED BY 'eastern_pass';
GRANT ALL PRIVILEGES ON openmrs_eastern.* TO 'eastern_user'@'%';

-- nairobi Tenant
CREATE DATABASE IF NOT EXISTS openmrs_nairobi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'nairobi_user'@'%' IDENTIFIED BY 'nairobi_pass';
GRANT ALL PRIVILEGES ON openmrs_nairobi.* TO 'nairobi_user'@'%';

-- northeastern Tenant
CREATE DATABASE IF NOT EXISTS openmrs_neastern CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'neastern_user'@'%' IDENTIFIED BY 'neastern_pass';
GRANT ALL PRIVILEGES ON openmrs_neastern.* TO 'neastern_user'@'%';

-- nyanza Tenant   
CREATE DATABASE IF NOT EXISTS openmrs_nyanza CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'nyanza_user'@'%' IDENTIFIED BY 'nyanza_pass';
GRANT ALL PRIVILEGES ON openmrs_nyanza.* TO 'nyanza_user'@'%';

-- riftvalley Tenant   
CREATE DATABASE IF NOT EXISTS openmrs_rift CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'rift_user'@'%' IDENTIFIED BY 'rift_pass';
GRANT ALL PRIVILEGES ON openmrs_rift.* TO 'rift_user'@'%';

-- western Tenant
CREATE DATABASE IF NOT EXISTS openmrs_western CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'western_user'@'%' IDENTIFIED BY 'western_pass';
GRANT ALL PRIVILEGES ON openmrs_western.* TO 'western_user'@'%';
