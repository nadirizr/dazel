from tests.utils import create_instance


def test_env_vars_are_empty_if_none_are_defined():
    instance = create_instance()
    assert not instance.env_vars


def test_single_env_var_in_string():
    instance = create_instance(env_vars="some_variable=some_value")
    assert instance.env_vars == '-e "some_variable=some_value"'


def test_multiple_env_vars_in_string():
    instance = create_instance(env_vars="variable1=value1,variable2=value2")
    assert instance.env_vars == '-e "variable1=value1" -e "variable2=value2"'


def test_single_env_var_in_iterable():
    instance = create_instance(env_vars=["some_variable=some_value"])
    assert instance.env_vars == '-e "some_variable=some_value"'


def test_multiple_env_vars_in_iterable():
    instance = create_instance(env_vars=["variable1=value1", "variable2=value2"])
    assert instance.env_vars == '-e "variable1=value1" -e "variable2=value2"'
