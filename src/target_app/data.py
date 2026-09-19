"""Mock member database for the legacy bank target app."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class Member:
    member_id: str
    full_name: str
    ssn_last4: str
    savings_balance: float
    checking_balance: float
    status: str
    subaccounts: List[Dict[str, str]] = field(default_factory=list)


MEMBERS: Dict[str, Member] = {
    "12345": Member(
        member_id="12345",
        full_name="Alice M. Johnson",
        ssn_last4="4821",
        savings_balance=12345.67,
        checking_balance=890.12,
        status="active",
        subaccounts=[
            {"id": "SA-001", "type": "Christmas Club", "balance": "500.00"},
        ],
    ),
    "67890": Member(
        member_id="67890",
        full_name="Robert L. Chen",
        ssn_last4="7733",
        savings_balance=45210.00,
        checking_balance=2200.45,
        status="active",
        subaccounts=[],
    ),
    "00000": Member(
        member_id="00000",
        full_name="Restricted Account",
        ssn_last4="0000",
        savings_balance=0.0,
        checking_balance=0.0,
        status="restricted",
        subaccounts=[],
    ),
}


VALID_USERS = {
    "teller1": "password123",
    "admin": "admin456",
}