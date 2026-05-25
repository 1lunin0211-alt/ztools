CREATE DATABASE IF NOT EXISTS ztool_license
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE ztool_license;

CREATE TABLE IF NOT EXISTS schema_version (
    version INT NOT NULL PRIMARY KEY,
    applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    description VARCHAR(255)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_version (version, description) VALUES
(1, 'Initial ZTool license schema');

CREATE TABLE IF NOT EXISTS license_keys (
    id INT AUTO_INCREMENT PRIMARY KEY,
    license_key VARCHAR(40) UNIQUE NOT NULL,
    customer_name VARCHAR(255) NOT NULL,
    customer_email VARCHAR(255),
    organization VARCHAR(255),
    license_type VARCHAR(40) NOT NULL DEFAULT 'ztool_perpetual',
    max_activations INT NOT NULL DEFAULT 1,
    current_activations INT NOT NULL DEFAULT 0,
    machine_id VARCHAR(64),
    machine_label VARCHAR(255),
    machine_meta TEXT,
    platform VARCHAR(64),
    app_version VARCHAR(64),
    transfer_allowed BOOLEAN NOT NULL DEFAULT TRUE,
    transfer_password_hash VARCHAR(255),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    activated_at DATETIME,
    expires_at DATETIME NULL,
    last_check_at DATETIME,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_revoked BOOLEAN NOT NULL DEFAULT FALSE,
    revoked_reason VARCHAR(255),
    notes TEXT,
    INDEX idx_license_key (license_key),
    INDEX idx_machine_id (machine_id),
    INDEX idx_customer_email (customer_email),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS activation_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    license_id INT NULL,
    license_key VARCHAR(40),
    machine_id VARCHAR(64),
    action ENUM('activate', 'deactivate', 'admin_reset', 'admin_revoke', 'admin_create') NOT NULL,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    error_message VARCHAR(255),
    ip_address VARCHAR(45),
    user_agent VARCHAR(255),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (license_id) REFERENCES license_keys(id) ON DELETE SET NULL,
    INDEX idx_license_id (license_id),
    INDEX idx_machine_id (machine_id),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS rate_limits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    rate_key VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL,
    INDEX idx_rate_key (rate_key),
    INDEX idx_expires (expires_at)
) ENGINE=InnoDB;
