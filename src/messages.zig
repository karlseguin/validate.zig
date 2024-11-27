pub const En = struct {
    pub const required = "required";
    pub const string_type = "must be a string";

    pub const string_len = \\must be between {min} and {max} {max, plural,
        \\ =1 {character}
        \\ other {characters}
        \\ } long
    ;

    pub const string_len_min = \\must be at least {min} {min, plural,
        \\ =1 {character}
        \\ other {characters}
        \\ }
    ;

    pub const string_len_max = \\must be no more than {max} {max, plural,
        \\ =1 {character}
        \\ other {characters}
        \\ }
    ;

    pub const int_type = "must be an integer";
    pub const int_min = "must be greater than or equal to {min}";
    pub const int_max = "must be less than or equal to {max}";
    pub const int_range = "must be between {min} and {max}";

    pub const bool_type = "must be a boolean";
};
