//! BitSync (BSY) amount type.
//!
//! * Name: **BitSync**
//! * Ticker: **BSY**
//! * Decimals: **8** (1 BSY = 10^8 base units; same scale as bitcoin sats)
//! * Max / total supply: **42_000_000 BSY** = `42_000_000 * 10^8` base units
//! * Inflation: **0%** — the EVM ERC-20 mints the full supply once at deployment
//!
//! Base units are stored in a `u64`. The maximum supply fits comfortably
//! (`42e6 * 1e8 = 4.2e15 < u64::MAX`).

use crate::error::CryptoError;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// Number of decimal places for BSY (matches the on-chain ERC-20 `decimals()`).
pub const BSY_DECIMALS: u8 = 8;

/// Multiplier `10^BSY_DECIMALS`.
pub const BSY_SCALE: u64 = 100_000_000;

/// Maximum / total supply in base units: 42,000,000 BSY.
pub const MAX_SUPPLY_BASE: u64 = 42_000_000 * BSY_SCALE;

/// Maximum / total supply in whole BSY tokens.
pub const MAX_SUPPLY_WHOLE: u64 = 42_000_000;

/// Human-readable ticker.
pub const BSY_SYMBOL: &str = "BSY";

/// Human-readable token name.
pub const BSY_NAME: &str = "BitSync";

/// An amount of BSY denominated in base units (1 BSY = 10^8 base units).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Amount(u64);

impl Amount {
    /// Zero.
    pub const ZERO: Self = Self(0);

    /// The maximum / total supply.
    pub const MAX_SUPPLY: Self = Self(MAX_SUPPLY_BASE);

    /// Construct from base units. Returns an error if `base > MAX_SUPPLY_BASE`
    /// when `enforce_cap` is used; the raw constructor allows any `u64` so
    /// intermediate arithmetic (e.g. fee numerators) can exist briefly.
    pub const fn from_base_units(base: u64) -> Self {
        Self(base)
    }

    /// Construct from base units, rejecting anything above [`MAX_SUPPLY_BASE`].
    pub fn from_base_units_checked(base: u64) -> Result<Self, CryptoError> {
        if base > MAX_SUPPLY_BASE {
            return Err(CryptoError::InvalidAmount(format!(
                "amount {base} exceeds MAX_SUPPLY_BASE"
            )));
        }
        Ok(Self(base))
    }

    /// Whole BSY tokens → base units, checked against the supply cap.
    pub fn try_from_whole(whole: u64) -> Result<Self, CryptoError> {
        whole
            .checked_mul(BSY_SCALE)
            .filter(|&v| v <= MAX_SUPPLY_BASE)
            .map(Self)
            .ok_or_else(|| CryptoError::InvalidAmount("whole amount overflow / exceeds cap".into()))
    }

    /// Base units.
    pub const fn as_base_units(self) -> u64 {
        self.0
    }

    /// Checked addition.
    pub fn checked_add(self, rhs: Self) -> Option<Self> {
        self.0.checked_add(rhs.0).map(Self)
    }

    /// Checked subtraction.
    pub fn checked_sub(self, rhs: Self) -> Option<Self> {
        self.0.checked_sub(rhs.0).map(Self)
    }

    /// Saturating addition capped at [`MAX_SUPPLY_BASE`].
    pub fn saturating_add_capped(self, rhs: Self) -> Self {
        Self(self.0.saturating_add(rhs.0).min(MAX_SUPPLY_BASE))
    }

    /// Parse strings like `"1.23456789"`, `"1.23456789 BSY"`, `"42000000"`.
    pub fn parse(s: &str) -> Result<Self, CryptoError> {
        let s = s.trim().trim_end_matches(BSY_SYMBOL).trim();
        if s.is_empty() {
            return Err(CryptoError::InvalidAmount("empty amount".into()));
        }
        let (whole_s, frac_s) = match s.split_once('.') {
            Some((w, f)) => (w, f),
            None => (s, ""),
        };
        if frac_s.len() > BSY_DECIMALS as usize {
            return Err(CryptoError::InvalidAmount(
                "too many fractional digits".into(),
            ));
        }
        if !whole_s.chars().all(|c| c.is_ascii_digit())
            || !frac_s.chars().all(|c| c.is_ascii_digit())
        {
            return Err(CryptoError::InvalidAmount("invalid amount charset".into()));
        }
        let whole: u64 = if whole_s.is_empty() {
            0
        } else {
            whole_s
                .parse()
                .map_err(|_| CryptoError::InvalidAmount("whole part overflow".into()))?
        };
        let mut frac: u64 = if frac_s.is_empty() {
            0
        } else {
            frac_s
                .parse()
                .map_err(|_| CryptoError::InvalidAmount("frac part overflow".into()))?
        };
        // Right-pad fractional part to 8 digits.
        for _ in frac_s.len()..(BSY_DECIMALS as usize) {
            frac *= 10;
        }
        let base = whole
            .checked_mul(BSY_SCALE)
            .and_then(|w| w.checked_add(frac))
            .ok_or_else(|| CryptoError::InvalidAmount("amount overflow".into()))?;
        Self::from_base_units_checked(base)
    }
}

impl fmt::Display for Amount {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let whole = self.0 / BSY_SCALE;
        let frac = self.0 % BSY_SCALE;
        if frac == 0 {
            write!(f, "{whole} {BSY_SYMBOL}")
        } else {
            write!(f, "{whole}.{frac:08} {BSY_SYMBOL}")
        }
    }
}

impl fmt::Debug for Amount {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Amount({self})")
    }
}

impl FromStr for Amount {
    type Err = CryptoError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Amount::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants() {
        assert_eq!(BSY_DECIMALS, 8);
        assert_eq!(BSY_SCALE, 100_000_000);
        assert_eq!(MAX_SUPPLY_BASE, 42_000_000 * 100_000_000);
        assert_eq!(MAX_SUPPLY_WHOLE, 42_000_000);
        assert_eq!(Amount::MAX_SUPPLY.as_base_units(), MAX_SUPPLY_BASE);
    }

    #[test]
    fn parse_and_format() {
        let a = Amount::parse("1.23456789 BSY").unwrap();
        assert_eq!(a.as_base_units(), 123_456_789);
        assert_eq!(a.to_string(), "1.23456789 BSY");
        assert_eq!(Amount::parse("42000000").unwrap(), Amount::MAX_SUPPLY);
        assert!(Amount::parse("42000001").is_err());
        assert!(Amount::parse("1.123456789").is_err()); // 9 decimals
    }

    #[test]
    fn checked_math() {
        let a = Amount::try_from_whole(1).unwrap();
        let b = Amount::try_from_whole(2).unwrap();
        assert_eq!(a.checked_add(b).unwrap().as_base_units(), 3 * BSY_SCALE);
        assert!(a.checked_sub(b).is_none());
        assert_eq!(
            Amount::MAX_SUPPLY.saturating_add_capped(a),
            Amount::MAX_SUPPLY
        );
    }
}
