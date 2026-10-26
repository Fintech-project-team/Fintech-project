"""Common bank/card identities; internal keys are not provider institution codes."""
from .banks import load_bank_directory

def institution_rows():
    """2026-10-23: Produce the reviewed bank directory plus the four agreed card providers."""
    banks=[{k:row[k] for k in ('code','kind','name')} for row in load_bank_directory()['banks']]
    cards=[{'code':'card.'+code,'kind':'card','name':name} for code,name in
           (('hyundai','현대'),('samsung','삼성'),('woori','우리'),('kb','국민'))]
    return banks+cards
