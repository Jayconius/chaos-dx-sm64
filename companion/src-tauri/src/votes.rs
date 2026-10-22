//! Reading votes out of chat messages, and counting them (one vote per chatter, first vote is final).

use std::collections::HashSet;

/// Characters a chatter may put in front of the number ("#2", "!3", "\"4\"", "(1)").
const LEADING: &[char] = &['#', '!', '"', '\'', '(', '[', '{', '<', '*', '-', '~', '.'];

/// Reads a vote from a chat message. The message must start with the number (after optional
/// symbols), may repeat the same digit ("111111"), and the number must be 1..=max.
/// "1", "111111111", "1! please", "#2", "!3" count; "12", "10", "I pick 3" don't.
pub fn parse_vote(message: &str, max: u8) -> Option<u8> {
    let text = message.trim_start().trim_start_matches(|c: char| LEADING.contains(&c) || c.is_whitespace());
    let mut chars = text.chars();
    let first = chars.next()?;
    let digit = first.to_digit(10)? as u8;
    if digit == 0 || digit > max {
        return None;
    }
    // a run of digits must all be the same digit ("1111" yes, "12" or "10" no)
    for c in chars {
        match c.to_digit(10) {
            Some(d) if d as u8 == digit => continue,
            Some(_) => return None,
            None => break,
        }
    }
    Some(digit)
}

/// Votes for one round. Resets whenever the game opens a new vote.
#[derive(Debug, Default)]
pub struct VoteBox {
    pub vote_id: u32,
    pub counts: [u32; 9],
    voters: HashSet<String>,
}

impl VoteBox {
    pub fn reset(&mut self, vote_id: u32) {
        self.vote_id = vote_id;
        self.counts = [0; 9];
        self.voters.clear();
    }

    /// Records a vote. Returns false if this chatter already voted this round.
    pub fn add(&mut self, user: &str, option: u8) -> bool {
        if option == 0 || option > 9 {
            return false;
        }
        if !self.voters.insert(user.to_ascii_lowercase()) {
            return false;
        }
        self.counts[(option - 1) as usize] += 1;
        true
    }

    pub fn total(&self) -> u32 {
        self.counts.iter().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_plain_and_repeated_numbers() {
        assert_eq!(parse_vote("1", 4), Some(1));
        assert_eq!(parse_vote("111111111", 4), Some(1));
        assert_eq!(parse_vote("2 2 2", 4), Some(2));
        assert_eq!(parse_vote("  3  ", 4), Some(3));
    }

    #[test]
    fn reads_numbers_with_extra_text() {
        assert_eq!(parse_vote("1! please", 4), Some(1));
        assert_eq!(parse_vote("#2", 4), Some(2));
        assert_eq!(parse_vote("!3", 4), Some(3));
        assert_eq!(parse_vote("\"4\"", 4), Some(4));
        assert_eq!(parse_vote("(1) lol", 4), Some(1));
        assert_eq!(parse_vote("3rd one", 4), Some(3));
    }

    #[test]
    fn rejects_non_votes() {
        assert_eq!(parse_vote("12", 9), None);
        assert_eq!(parse_vote("10", 9), None);
        assert_eq!(parse_vote("0", 9), None);
        assert_eq!(parse_vote("I pick 3", 4), None);
        assert_eq!(parse_vote("", 4), None);
        assert_eq!(parse_vote("hello", 4), None);
    }

    #[test]
    fn respects_option_count() {
        assert_eq!(parse_vote("5", 4), None);
        assert_eq!(parse_vote("5", 5), Some(5));
        assert_eq!(parse_vote("9", 9), Some(9));
    }

    #[test]
    fn one_vote_per_chatter_first_is_final() {
        let mut b = VoteBox::default();
        b.reset(7);
        assert!(b.add("Alice", 1));
        assert!(!b.add("alice", 2)); // same chatter, any case: ignored
        assert!(b.add("Bob", 2));
        assert_eq!(b.counts[0], 1);
        assert_eq!(b.counts[1], 1);
        assert_eq!(b.total(), 2);
        b.reset(8);
        assert!(b.add("Alice", 3)); // new round, can vote again
        assert_eq!(b.total(), 1);
    }
}
