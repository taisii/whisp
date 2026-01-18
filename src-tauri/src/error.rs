use std::fmt;

pub type AppResult<T> = Result<T, AppError>;

#[derive(Debug)]
pub enum AppError {
    Io(String),
    TomlDe(String),
    TomlSer(String),
    Reqwest(String),
    WebSocket(String),
    Audio(String),
    ConfigDirMissing,
    MissingApiKey(&'static str),
    Shortcut(String),
    AccessibilityPermissionRequired,
    Other(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppError::Io(msg) => write!(f, "io error: {msg}"),
            AppError::TomlDe(msg) => write!(f, "toml decode error: {msg}"),
            AppError::TomlSer(msg) => write!(f, "toml encode error: {msg}"),
            AppError::Reqwest(msg) => write!(f, "http error: {msg}"),
            AppError::WebSocket(msg) => write!(f, "websocket error: {msg}"),
            AppError::Audio(msg) => write!(f, "audio error: {msg}"),
            AppError::ConfigDirMissing => write!(f, "config directory not found"),
            AppError::MissingApiKey(name) => write!(f, "missing api key: {name}"),
            AppError::Shortcut(msg) => write!(f, "shortcut error: {msg}"),
            AppError::AccessibilityPermissionRequired => {
                write!(f, "accessibility permission required")
            }
            AppError::Other(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for AppError {}

impl From<std::io::Error> for AppError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

impl From<toml::de::Error> for AppError {
    fn from(value: toml::de::Error) -> Self {
        Self::TomlDe(value.to_string())
    }
}

impl From<toml::ser::Error> for AppError {
    fn from(value: toml::ser::Error) -> Self {
        Self::TomlSer(value.to_string())
    }
}

impl From<reqwest::Error> for AppError {
    fn from(value: reqwest::Error) -> Self {
        Self::Reqwest(value.to_string())
    }
}

impl From<tokio_tungstenite::tungstenite::Error> for AppError {
    fn from(value: tokio_tungstenite::tungstenite::Error) -> Self {
        Self::WebSocket(value.to_string())
    }
}
