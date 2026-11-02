"""Validate approved data with the production readers, without inference."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend/dish_pipeline/src'))


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def strict_json(path):
    def invalid(value):
        raise ValueError('Non-finite JSON number: ' + value)
    return json.loads(Path(path).read_bytes(), object_pairs_hook=unique,
                      parse_constant=invalid)


def validate(root=ROOT):
    from dish_identifier.ingredient_data import IngredientData
    from dish_identifier.dish_display import DishDisplayNames
    root = Path(root)
    hashes = strict_json(root / 'data/approved-hashes.json')
    for name, digest in hashes.items():
        path = root / 'data' / name
        if path.parent != root / 'data' or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Unapproved dataset identity: ' + name)
        strict_json(path)
    schema = strict_json(root / 'backend/dish_pipeline/src/dish_identifier/assets/ingredient_schema.json')
    categories = schema['properties']['ingredients']['items']['properties']['allergens']['items']['enum']
    classes = strict_json(root / 'backend/dish_pipeline/nonlinear/shared/class_mapping.json')['classes']
    ingredients = IngredientData(root / 'data/Misbar_Normlized_IngredientsXAllergen.json', categories)
    names = DishDisplayNames(root / 'data/misbar_dish_name_mapping.json', classes)
    if set(ingredients.dishes) != set(classes):
        raise ValueError('Ingredient dishes must exactly match the frozen classes.')
    for dish, row in ingredients.dishes.items():
        retrieved = ingredients.retrieve(dish)
        for original, actual in zip(row['normalizedIngredients'], retrieved['ingredients'], strict=True):
            if original != actual['original_record'] or original['allergens'] != actual['allergens']:
                raise ValueError('Recorded ingredient evidence changed.')
    return {'dishes': len(classes), 'ingredients_sha256': ingredients.identity['sha256'],
            'mapping_sha256': names.identity['sha256']}


if __name__ == '__main__':
    print(json.dumps(validate(), indent=2))
