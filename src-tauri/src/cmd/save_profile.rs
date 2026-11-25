use super::CmdResult;
use crate::{
    cmd::StringifyErr as _,
    cmd::validate::{ValidationNoticeTarget, handle_validation_notice},
    config::{Config, IProfiles, PrfItem, profiles::PROFILE_WRITE_LOCK},
    core::auto_backup::{AutoBackupManager, AutoBackupTrigger},
    core::{
        CoreManager, handle,
        validate::{CoreConfigValidator, ValidationOutcome},
    },
    tunnelmaster_profiles::WIREGUARD_PROFILE_PREFIX,
    utils::{dirs, help},
};
use clash_verge_logging::{Type, logging};
use smartstring::alias::String;
use tokio::fs;

/// 保存profiles的配置
#[tauri::command]
#[specta::specta]
pub async fn save_profile_file(
    index: std::string::String,
    file_data: Option<std::string::String>,
) -> CmdResult<ValidationOutcome> {
    let file_data = match file_data {
        Some(data) => String::from(data),
        None => return Ok(ValidationOutcome::Valid),
    };
    transform_profile_file(index.into(), |_| Ok(Some(file_data))).await
}

pub(crate) async fn transform_profile_file<F>(index: String, transform: F) -> CmdResult<ValidationOutcome>
where
    F: FnOnce(&str) -> CmdResult<Option<String>> + Send,
{
    let _write = PROFILE_WRITE_LOCK.lock().await;
    let private = index.starts_with(WIREGUARD_PROFILE_PREFIX);
    let backup_trigger = match index.as_str() {
        "Merge" => Some(AutoBackupTrigger::GlobalMerge),
        "Script" => Some(AutoBackupTrigger::GlobalScript),
        _ => None,
    };

    // 在异步操作前获取必要元数据并释放锁
    let (rel_path, is_merge_file, is_script_file, affects_runtime) = {
        let profiles = Config::profiles().await;
        let profiles_guard = profiles.latest_arc();
        let item = profiles_guard.get_item(&index).stringify_err()?;
        let is_merge = item.itype.as_ref().is_some_and(|t| t == "merge");
        let path = item.file.clone().ok_or("file field is null")?;
        let is_script = item.itype.as_ref().is_some_and(|t| t == "script") || path.ends_with(".js");
        let affects_runtime = profile_affects_runtime(&profiles_guard, &index);
        (path, is_merge, is_script, affects_runtime)
    };

    let profiles_dir = dirs::app_profiles_dir().stringify_err()?;
    let file_path = profiles_dir.join(rel_path.as_str());

    // 读取原始内容（在释放profiles_guard后进行）
    let original_existed = fs::try_exists(&file_path).await.map_err(|err| {
        String::from(format!(
            "failed to check profile file \"{}\": {err}",
            file_path.display()
        ))
    })?;
    let original_content = if original_existed {
        PrfItem {
            file: Some(rel_path.clone()),
            ..Default::default()
        }
        .read_file()
        .await
        .stringify_err()?
    } else {
        String::new()
    };

    let Some(file_data) = transform(&original_content)? else {
        return Ok(ValidationOutcome::Valid);
    };
    save_profile_data(&file_path, &file_data, private).await?;

    let changes_applied = handle_saved_profile_file(
        &file_path,
        &original_content,
        original_existed,
        is_merge_file,
        is_script_file,
        affects_runtime,
        private,
    )
    .await?;

    if changes_applied.is_valid()
        && let Some(trigger) = backup_trigger
    {
        AutoBackupManager::trigger_backup(trigger);
    }

    Ok(changes_applied)
}

async fn restore_original(
    file_path: &std::path::Path,
    original_content: &str,
    original_existed: bool,
    private: bool,
) -> CmdResult<()> {
    if original_existed {
        save_profile_data(file_path, original_content, private).await
    } else {
        fs::remove_file(file_path).await.stringify_err()
    }
}

async fn save_profile_data(file_path: &std::path::Path, data: &str, private: bool) -> CmdResult<()> {
    if private {
        help::save_private_yaml_str(file_path, data).await.stringify_err()
    } else {
        fs::write(file_path, data).await.stringify_err()
    }
}

fn profile_affects_runtime(profiles: &IProfiles, index: &str) -> bool {
    let Some(current_uid) = profiles.current.as_ref() else {
        return false;
    };
    if current_uid == index {
        return true;
    }

    let Ok(item) = profiles.get_item(current_uid) else {
        return false;
    };
    [
        item.current_merge().map_or("Merge", String::as_str),
        item.current_script().map_or("Script", String::as_str),
        item.current_rules().map_or("Rules", String::as_str),
        item.current_proxies().map_or("Proxies", String::as_str),
        item.current_groups().map_or("Groups", String::as_str),
    ]
    .contains(&index)
}

async fn handle_saved_profile_file(
    file_path: &std::path::Path,
    original_content: &str,
    original_existed: bool,
    is_merge_file: bool,
    is_script_file: bool,
    affects_runtime: bool,
    private: bool,
) -> CmdResult<ValidationOutcome> {
    let (target, file_type) = if is_script_file {
        (ValidationNoticeTarget::Script, "脚本文件")
    } else if is_merge_file {
        (ValidationNoticeTarget::Merge, "合并配置文件")
    } else {
        (ValidationNoticeTarget::Runtime, "YAML配置文件")
    };

    match CoreConfigValidator::validate_config_file_outcome(&file_path.to_string_lossy(), Some(is_merge_file)).await {
        Ok(outcome) if outcome.is_valid() => {}
        Ok(outcome) => {
            logging!(warn, Type::Config, "[cmd配置save] 文件验证失败: {}", outcome);
            restore_original(file_path, original_content, original_existed, private).await?;
            handle_validation_notice(&outcome, target, file_type);
            return Ok(outcome);
        }
        Err(e) => {
            logging!(error, Type::Config, "[cmd配置save] 验证过程发生错误: {e:#}");
            restore_original(file_path, original_content, original_existed, private).await?;
            return Err(e.to_string().into());
        }
    }

    if !affects_runtime {
        return Ok(ValidationOutcome::Valid);
    }

    logging!(
        info,
        Type::Config,
        "[cmd配置save] 保存项影响当前运行时配置，开始统一应用"
    );
    match CoreManager::global().update_config_forced().await {
        Ok(outcome) if outcome.is_valid() => {
            handle::Handle::refresh_clash();
            Ok(ValidationOutcome::Valid)
        }
        Ok(outcome) => {
            logging!(warn, Type::Config, "[cmd配置save] 运行时配置应用失败: {}", outcome);
            restore_original(file_path, original_content, original_existed, private).await?;
            handle_validation_notice(&outcome, ValidationNoticeTarget::Runtime, "运行时配置");
            Ok(outcome)
        }
        Err(err) => {
            logging!(error, Type::Config, "[cmd配置save] 运行时配置应用错误: {err:#}");
            restore_original(file_path, original_content, original_existed, private).await?;
            Err(err.to_string().into())
        }
    }
}
