from typing import List, Optional

try:
    from pydantic import BaseModel, Field, StrictStr
except ImportError:
    StrictStr = str
    # Lightweight fallback when pydantic is not yet installed
    class BaseModel:
        def __init__(self, **kwargs):
            for k, v in kwargs.items():
                setattr(self, k, v)
        def dict(self, *args, **kwargs):
            return self.__dict__
        def model_dump(self, *args, **kwargs):
            return self.__dict__
    def Field(default=..., **kwargs):
        return default

class AllergenDetection(BaseModel):
    allergen: str = Field(..., description="Category of the detected allergen, e.g. 'Milk'")
    matched_ingredients: List[str] = Field(..., description="List of matched ingredients or keywords found in the text")
    is_user_allergen: bool = Field(False, description="Whether this allergen matches the user's specific allergy profile")

class ScanResponse(BaseModel):
    success: bool = True
    status: str = Field("completed", description="Scan outcome status: 'completed', 'no_text', or 'no_ingredients'")
    error_title: Optional[str] = Field(None, description="Bilingual error title if scan failed or could not find ingredients")
    is_safe: bool = Field(..., description="True if no allergens (or none of user's personal allergens) are present")
    extracted_ocr_text: str = Field(..., description="Raw text extracted from image OCR")
    ingredient_list: str = Field(..., description="Isolated ingredient list extracted by Open Food Facts AI model")
    allergens_detected: List[AllergenDetection] = Field(default_factory=list)
    total_allergens_count: int = 0
    ocr_engine: str = Field("unknown", description="OCR engine used ('google_vision', 'easyocr', or 'provided_text')")
    message: Optional[str] = None

class ScanTextRequest(BaseModel):
    text: str = Field(..., description="Raw packaging text or on-device OCR text to analyze")

class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
    model_path: str
    ocr_engine_available: bool
    ocr_engine_name: str
    allergen_keywords_count: int
    dataset_file: Optional[str]

class AllergensListResponse(BaseModel):
    categories: List[str]
    total_categories: int
    total_keywords: int

class UserProfileResponse(BaseModel):
    uid: str
    email: Optional[str] = None
    name: Optional[str] = None
    allergies: List[str] = Field(default_factory=list)
    allergy_selection_saved: bool = True
    language: StrictStr = "en"
    role: StrictStr = "member"

class UserProfileUpdateRequest(BaseModel):
    name: Optional[str] = None
    email: Optional[str] = None

class UserAllergiesResponse(BaseModel):
    allergies: List[str] = Field(default_factory=list)
    allergy_selection_saved: bool = True

class UserAllergiesUpdateRequest(BaseModel):
    allergies: List[StrictStr] = Field(..., min_length=1, max_length=14, strict=True)
