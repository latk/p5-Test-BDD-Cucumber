package Test::BDD::Cucumber::Parser;

=head1 NAME

Test::BDD::Cucumber::Parser - Parse Feature files

=head1 DESCRIPTION

Parse Feature files in to a set of data classes

=head1 SYNOPSIS

 # Returns a Test::BDD::Cucumber::Model::Feature object
 my $feature = Test::BDD::Cucumber::Parser->parse_file(
    't/data/features/basic_parse.feature' );

=head1 METHODS

=head2 parse_string

=head2 parse_file

Both methods accept a single string as their argument, and return a
L<Test::BDD::Cucumber::Model::Feature> object on success.

=cut

use strict;
use warnings;

use Test::BDD::Cucumber::Model::Document;
use Test::BDD::Cucumber::Model::Feature;
use Test::BDD::Cucumber::Model::Scenario;
use Test::BDD::Cucumber::Model::Step;
use Test::BDD::Cucumber::Model::TagSpec;
use Test::BDD::Cucumber::I18n qw(langdef);
use Test::BDD::Cucumber::Errors qw/parse_error_from_line/;

# https://github.com/cucumber/cucumber/wiki/Multiline-Step-Arguments
# https://github.com/cucumber/cucumber/wiki/Scenario-outlines

sub parse_string {
    my ( $class, $string ) = @_;

    return $class->_construct(
        Test::BDD::Cucumber::Model::Document->new(
            {
                content => $string
            }
        )
    );
}

sub parse_file {
    my ( $class, $filename ) = @_;
    local $/;
    open( my $in, '<:utf8', $filename ) or die $?;
    return $class->_construct(
        Test::BDD::Cucumber::Model::Document->new(
            {
                content  => <$in>,
                filename => '' . $filename
            }
        )
    );
}

sub _construct {
    my ( $class, $document ) = @_;

    my $lines = [ @{ $document->lines } ];

    my $self = { langdef => 'FIX', lines => $lines };
    bless $self, $class;

    $self->_skip_blank;
    my $language = $self->_extract_language;

    my %langdef = %{ langdef( $language ) };
    $langdef{_any_scenario} = join q(|),
      @langdef{qw/ background scenario scenario_outline /};
    $langdef{_any_verb} = join q(|), @langdef{qw/ given and when then but /};
    $langdef{_default_verb} =
      ( split /\|/, $langdef{given} )[-1];
    $self->{langdef} = \%langdef;

    my $feature = Test::BDD::Cucumber::Model::Feature->new(
        {
            document => $document,
            language => $language
        }
    );

    $self->_extract_feature_name( $feature );
    $self->_extract_conditions_of_satisfaction( $feature );
    $self->_extract_scenarios( $feature );
    return $feature;
}

sub _extract_language {
    my ( $self ) = @_;
    my $language = 'en';

    if ( $self->_peek_line->raw_content =~ m/^\s*\#\s*language:\s+(.+)$/ ) {
        $language = $1;
        $self->_read_line;
    }

    return $language;
}

sub _skip_blank {
    my ( $self ) = @_;
    while ( $self->_peek_line and $self->_peek_line->is_blank ) {
        $self->_read_line;
    }
    return;
}

sub _extract_feature_name {
    my ( $self, $feature ) = @_;
    my $langdef      = $self->{langdef};
    my @feature_tags = ();

    while ( my $line = $self->_read_line ) {
        next if $line->is_comment;
        last if $line->is_blank;

        if ( $line->content =~ m/^(?:$langdef->{feature}): (.+)/ ) {
            $feature->name( $1 );
            $feature->name_line( $line );
            $feature->tags( \@feature_tags );

            last;

            # Feature-level tags
        } elsif ( my @tags = $self->_extract_tags( $line ) ) {
            push( @feature_tags, @tags );

        } else {
            die parse_error_from_line(
                'Malformed feature line '
                  . "(expecting: /^(?:$langdef->{feature}): (.+)/)",
                $line
            );
        }
    }

    return;
}

sub _extract_tags {
    my ( $self, $line ) = @_;

    return unless $line->content =~ m/^\s*\@\w/;
    my @tags = $line->content =~ m/\@([^\s]+)/g;
    return @tags;
}

sub _extract_conditions_of_satisfaction {
    my ( $self, $feature ) = @_;
    my $langdef = $self->{langdef};

    while ( my $line = $self->_read_content_line ) {
        if ( $line->content =~ m/^(?:(?:$langdef->{_any_scenario}):|\@)/ ) {
            $self->_unread_line( $line );
            last;
        } else {
            push( @{ $feature->satisfaction }, $line );
        }
    }

    return;
}

sub _extract_scenarios {
    my ( $self, $feature ) = @_;
    while ( my $scenario = $self->_extract_scenario( $feature ) ) {

        # Only one background section, and it must be first
        if ( $scenario->background ) {
            die parse_error_from_line( "Background not allowed after scenarios",
                $scenario->line )
              if @{ $feature->scenarios };
            $feature->background( $scenario );
        } else {
            push( @{ $feature->scenarios }, $scenario );
        }
    }
    return;
}

sub _extract_scenario {
    my ( $self, $feature ) = @_;
    my @scenario_tags;
    my $langdef = $self->{langdef};

    my $line;    # may hold previous line
    while ( $line = $self->_read_content_line ) {

        # Scenario-level tags
        if ( my @tags = $self->_extract_tags( $line ) ) {
            push( @scenario_tags, @tags );
            next;
        }

        $self->_unread_line( $line );
        last;
    }

    # check if input was exhausted
    if ( !$self->_peek_line ) {
        die parse_error_from_line( "Expected scenario after tags", $line )
          if @scenario_tags;
        return;    # no scenario left
    }

    $line = $self->_read_content_line;
    $line->content =~ m/^($langdef->{_any_scenario}): ?(.+)?/
      or die parse_error_from_line( "Malformed scenario line", $line );

    my ( $type, $name ) = ( $1, $2 );
    my $is_background       = 0+ ( $type =~ m/^($langdef->{background})/ );
    my $is_scenario_outline = 0+ ( $type =~ /^($langdef->{scenario_outline})/ );

    # Create the scenario
    my $scenario = Test::BDD::Cucumber::Model::Scenario->new(
        {
            ( $name ? ( name => $name ) : () ),
            background => $is_background,
            line       => $line,
            tags       => [ @{ $feature->tags }, @scenario_tags ]
        }
    );

    # Attempt to populate it
    $self->_extract_steps( $feature, $scenario );

    # Catch Scenario outlines without examples
    if ( $is_scenario_outline && !@{ $scenario->data } ) {
        die parse_error_from_line(
            "Outline scenario expects 'Examples:' section", $line );
    }

    return $scenario;
}

sub _extract_steps {
    my ( $self, $feature, $scenario ) = @_;
    my $langdef   = $self->{langdef};
    my $last_verb = $langdef->{_default_verb};

    while ( my $line = $self->_read_content_line ) {

        # Start of the next scenario
        if ( $line->content =~
            m/^(?:$langdef->{scenario}|$langdef->{scenario_outline}):|^\@/ )
        {
            $self->_unread_line( $line );
            return;
        }

        # Trailing example block
        # TODO multiple example blocks with different tags
        if ( $line->content =~ m/^(?:$langdef->{examples}):$/ ) {
            my ( $columns, $data, $lines ) = $self->_extract_table
              or die parse_error_from_line( "Expected table in example section",
                $line );
            $scenario->data( $data );
            return;
        }

        # A conventional step
        $line->content =~ m/^($langdef->{_any_verb}) (.+)/
          or die parse_error_from_line( "Malformed step line", $line );

        my ( $original_verb, $text ) = ( $1, $2 );
        my $verb = $self->_determine_verb( $original_verb, $last_verb );
        $last_verb = $verb;

        my $step = Test::BDD::Cucumber::Model::Step->new(
            {
                text          => $text,
                verb          => $verb,
                line          => $line,
                verb_original => $original_verb,
            }
        );

        $self->_extract_step_data( $step );

        push( @{ $scenario->steps }, $step );
    }

    return;
}

sub _determine_verb {
    my ( $self, $verb, $prev ) = @_;
    my $langdef = $self->{langdef};
    return 'Given' if $verb =~ m/^($langdef->{given})$/;
    return 'When'  if $verb =~ m/^($langdef->{when})$/;
    return 'Then'  if $verb =~ m/^($langdef->{then})$/;
    return $prev   if $verb =~ m/^($langdef->{and}|$langdef->{but})$/;
    return $verb;
}

sub _extract_step_data {
    my ( $self, $step ) = @_;

    if ( my ( $data, $lines ) = $self->_extract_multiline_string ) {
        $step->data( $data );
        $step->data_as_strings( $lines );
        return;
    }

    if ( my ( $columns, $data, $lines ) = $self->_extract_table ) {
        $step->columns( $columns );
        $step->data( $data );
        $step->data_as_strings( $lines );
        return;
    }

    return;
}

sub _extract_multiline_string {
    my ( $self ) = @_;

    my $start = $self->_peek_line;
    return unless $start;

    return unless $start->content =~ m/^("""|```)(\w+)?$/;
    my ( $delimiter, $content_type ) = ( $1, $2 );
    my $indent = $start->indent;

    $self->_read_line;

    # TODO Check we still have the minimum indentation
    my $data = '';
    my @data_as_strings;
    my $line;
    while () {
        my $prev_line = $line;
        my $line      = $self->_read_line
          or die parse_error_from_line( "Multiline string not terminated",
            $prev_line );

        last if $line->content eq $delimiter;

        my $content = $line->content_remove_indentation( $indent );
        $content =~ s/\\(.)/$1/g;    # unescape content

        push( @data_as_strings, $content );
        $data .= $content . "\n";
    }
    return $data, \@data_as_strings;
}

sub _extract_table {
    my ( $self ) = @_;
    my @columns;
    my @data;
    my @lines;

    $self->_skip_blank;
    while ( my $line = $self->_read_line ) {
        next if $line->is_comment;

        if ( $line->content !~ /^\|/ ) {
            $self->_unread_line( $line );
            last;
        }

        push( @lines, $line->content );

        my ( undef, @row ) = split /\s*(?<!\\)\|\s*/, $line->content;
        s/\\(.)/$1/g for @row;

        if ( @columns ) {
            die parse_error_from_line( "Inconsistent number of rows in table",
                $line )
              unless @row == @columns;
            my %data_hash;
            @data_hash{@columns} = @row;
            push( @data, \%data_hash );
        } else {
            @columns = @row;
        }
    }

    return unless @columns;
    return \@columns, \@data, \@lines;
}

sub _peek_line {
    my ( $self ) = @_;
    return $self->{lines}->[0];
}

sub _read_line {
    my ( $self ) = @_;
    return shift( @{ $self->{lines} } );
}

sub _read_content_line {
    my ( $self ) = @_;
    while ( my $line = shift( @{ $self->{lines} } ) ) {
        next if $line->is_blank || $line->is_comment;
        return $line;
    }
    return;
}

sub _unread_line {
    my ( $self, $line ) = @_;
    unshift( @{ $self->{lines} }, $line );
    return;
}

1;

=head1 AUTHOR

Peter Sergeant C<pete@clueball.com>

=head1 LICENSE

Copyright 2011-2016, Peter Sergeant; Licensed under the same terms as Perl

=cut
